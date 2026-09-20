# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.EditTest do
  use ExUnit.Case, async: false

  # Edit tests compile a probe resource from a temporary copy of a fixture
  # (module renamed, so the repo's own test resources are untouched), then
  # exercise the operations against that copy: the compiled module's Spark
  # annotations point at the temporary file, which is exactly the flow a
  # real edit takes. Serialized (async: false) because the probes mutate
  # the shared code namespace.

  alias AshAgentTools.Edit

  @fixture "test/support/post.ex"
  @module_prefix "AshAgentTools.Test.EditProbe"

  setup do
    unique = System.unique_integer([:positive])
    module = Module.concat(["#{@module_prefix}#{unique}"])
    dir = Path.join(System.tmp_dir!(), "ash_agent_tools_edit_#{unique}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "edit_probe.ex")

    @fixture
    |> File.read!()
    |> String.replace("defmodule AshAgentTools.Test.Post do", "defmodule #{module} do")
    |> then(&File.write!(file, &1))

    # mix test runs the suite with debug_info off, which would strip the
    # Spark annotations this whole suite depends on — force them back on.
    previous_debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    Code.compile_file(file)

    Code.put_compiler_option(:debug_info, previous_debug_info)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      File.rm_rf!(dir)
    end)

    %{module: module, path: file, name: module |> Module.split() |> Enum.join(".")}
  end

  defp digest!(path), do: Edit.shape(path).digest

  describe "shape/1" do
    test "digests the symbol table of the annotated file", %{path: path} do
      shape = Edit.shape(path)

      assert %{
               file: ^path,
               digest: digest,
               symbols: symbols
             } = shape

      assert String.length(digest) == 64
      assert Enum.any?(symbols, &(&1.name_path =~ "/attributes/score"))
      assert Enum.any?(symbols, &(&1.name_path =~ "/actions/create"))

      # the module-level synthetic actions are not in the shape (no lines)
      refute Enum.any?(symbols, &(&1.name_path =~ "/actions/read"))
    end

    test "nil for files no Ash module annotates" do
      assert Edit.shape("mix.exs") == nil
      assert Edit.shape(nil) == nil
    end

    test "digest is stable across reads and moves when the structure moves", %{path: path} do
      digest = digest!(path)
      assert digest!(path) == digest

      line = File.read!(path)
      File.write!(path, "# a comment moved nothing structural\n" <> line)
      # the symbol table moved by one line -> new digest
      refute digest!(path) == digest
    end
  end

  describe "replace_entity_block/3" do
    test "dry-run plans the edit, returns the diff and digest, and writes nothing", %{
      module: module,
      path: path,
      name: name
    } do
      original = File.read!(path)
      before = File.read!(path)

      {:ok, report} =
        Edit.replace_entity_block(
          "#{name}/attributes/score",
          "attribute :score, :integer, allow_nil?: false",
          []
        )

      assert report.dry_run?
      assert report.write? == false
      assert report.name_path == "#{name}/attributes/score"
      assert report.diff =~ "@@ line "
      assert report.diff =~ "attribute :score, :integer, allow_nil?: false"
      assert report.current_digest == digest!(path)
      assert File.read!(path) == before
      assert original == before
    end

    test "a write round-trips: splices precisely, preserves formatting and EOLs, passes the gate",
         %{module: module, path: path, name: name} do
      original = File.read!(path)

      {:ok, plan} =
        Edit.replace_entity_block(
          "#{name}/attributes/score",
          "attribute :score, :integer, allow_nil?: false",
          []
        )

      {:ok, report} =
        Edit.replace_entity_block(
          "#{name}/attributes/score",
          "attribute :score, :integer, allow_nil?: false",
          write: true,
          expected_digest: plan.current_digest
        )

      assert report.applied?
      assert report.gate.compile == "ok"
      assert report.gate.validate == "ok"
      assert report.new_digest != plan.current_digest

      content = File.read!(path)
      assert content =~ "attribute :score, :integer, allow_nil?: false"

      # formatting preserved: everything outside the replaced block is
      # byte-identical
      assert strip_block(original, "attribute :score, :integer, public?: true") ==
               strip_block(content, "attribute :score, :integer, allow_nil?: false")
    end

    test "body indentation is normalized to the anchor's", %{path: path, name: name} do
      digest = digest!(path)
      original = File.read!(path)

      # deliberately over-indented body: the anchor sits at four spaces
      {:ok, _} =
        Edit.replace_entity_block(
          "#{name}/attributes/score",
          "      attribute :score, :integer do\n        public? true\n      end",
          write: true,
          expected_digest: digest
        )

      content = File.read!(path)
      assert content =~ "\n    attribute :score, :integer do\n      public? true\n    end\n"

      assert strip_block(original, "attribute :score, :integer, public?: true") ==
               strip_block(content, "attribute :score, :integer do\n      public? true\n    end")
    end

    test "CRLF files keep their EOLs", %{module: module, path: path, name: name} do
      original = File.read!(path)
      File.write!(path, String.replace(original, "\n", "\r\n"))
      digest = digest!(path)

      {:ok, _} =
        Edit.replace_entity_block(
          "#{name}/attributes/score",
          "attribute :score, :integer, allow_nil?: false",
          write: true,
          expected_digest: digest
        )

      content = File.read!(path)
      assert content =~ "\r\n"
      refute content =~ ~r/[^\r]\n/
    end

    test "stale digests refuse the write", %{path: path, name: name} do
      {:ok, plan} =
        Edit.replace_entity_block("#{name}/attributes/score", "attribute :score, :integer", [])

      {:error, report} =
        Edit.replace_entity_block("#{name}/attributes/score", "attribute :score, :integer",
          write: true,
          expected_digest: "deadbeef"
        )

      assert report.error == "stale_file"
      assert report.expected_digest == "deadbeef"
      assert report.current_digest == plan.current_digest
      assert File.read!(path) == File.read!(path)
    end

    test "a write without a digest is refused (mechanical read-before-edit)", %{
      path: path,
      name: name
    } do
      {:error, report} =
        Edit.replace_entity_block("#{name}/attributes/score", "attribute :score, :integer",
          write: true
        )

      assert report.error == "expected_digest_required"
      assert is_binary(report.current_digest)
    end

    test "unparseable bodies are refused before anything happens", %{path: path, name: name} do
      {:error, report} =
        Edit.replace_entity_block("#{name}/attributes/score", "attribute :score, :integer, )(")

      assert report.error == "unparseable_body"
    end

    test "synthetic (transformer-injected) symbols are refused", %{name: name} do
      {:error, report} = Edit.replace_entity_block("#{name}/actions/read", "read")

      assert report.error == "synthetic_symbol"
      assert report.message =~ "transformer-injected"
    end

    test "a bad compile gate reverts the file", %{path: path, name: name} do
      original = File.read!(path)
      digest = digest!(path)

      # parses as an expression, but is not valid Ash DSL: compile error
      {:error, report} =
        Edit.replace_entity_block(
          "#{name}/attributes/score",
          "attribute :score, :not_a_real_type",
          write: true,
          expected_digest: digest
        )

      assert report.error == "post_edit_gate_failed"
      assert report.reverted?
      assert File.read!(path) == original
    end
  end

  describe "insert_after_entity/3 and insert_before_entity/3" do
    test "inserts with one blank line of separation and passes the gate", %{
      path: path,
      name: name
    } do
      digest = digest!(path)

      {:ok, report} =
        Edit.insert_after_entity(
          "#{name}/attributes/score",
          "attribute :reviewed, :boolean, default: false",
          write: true,
          expected_digest: digest
        )

      assert report.applied?
      assert report.gate.compile == "ok"

      content = File.read!(path)

      assert content =~
               "attribute :score, :integer, public?: true\n\n    attribute :reviewed, :boolean, default: false"
    end

    test "insert-before lands immediately above the anchor", %{path: path, name: name} do
      digest = digest!(path)

      {:ok, _} =
        Edit.insert_before_entity(
          "#{name}/attributes/score",
          "attribute :memo, :string",
          write: true,
          expected_digest: digest
        )

      content = File.read!(path)

      assert content =~
               "attribute :memo, :string\n\n    attribute :score, :integer, public?: true"
    end

    test "the inserted attribute becomes addressable after the gate", %{name: name, path: path} do
      digest = digest!(path)

      {:ok, _} =
        Edit.insert_after_entity(
          "#{name}/attributes/score",
          "attribute :reviewed, :boolean, default: false",
          write: true,
          expected_digest: digest
        )

      assert {:ok, report} = AshAgentTools.resolve("#{name}/attributes/reviewed")
      assert report.symbol.provenance == :source
      assert report.symbol.source.file == path
    end
  end

  describe "safe_delete_entity/2" do
    test "refuses while the entity is referenced, with the reference list", %{name: name} do
      {:error, report} = Edit.safe_delete_entity("#{name}/attributes/title")

      assert report.error == "has_references"
      assert report.references != []
      assert Enum.any?(report.references, &(&1.name == :create))
    end

    test "deletes an unreferenced entity and passes the gate", %{path: path, name: name} do
      # add a standalone attribute first
      {:ok, plan} =
        Edit.insert_after_entity(
          "#{name}/attributes/score",
          "attribute :standalone, :string",
          []
        )

      {:ok, _} =
        Edit.insert_after_entity("#{name}/attributes/score", "attribute :standalone, :string",
          write: true,
          expected_digest: plan.current_digest
        )

      {:ok, delete_plan} = Edit.safe_delete_entity("#{name}/attributes/standalone")
      assert delete_plan.dry_run?

      {:ok, report} =
        Edit.safe_delete_entity("#{name}/attributes/standalone",
          write: true,
          expected_digest: delete_plan.current_digest
        )

      assert report.applied?
      refute File.read!(path) =~ "standalone"

      # gone from the DSL state too: resolving it now raises
      assert_raise ArgumentError, ~r/has no attributes\/standalone/, fn ->
        AshAgentTools.resolve("#{name}/attributes/standalone")
      end
    end
  end

  describe "error-path JSON discipline" do
    test "every error report is JSON-encodable", %{name: name} do
      reports = [
        Edit.replace_entity_block("#{name}/actions/read", "read"),
        Edit.replace_entity_block("#{name}/attributes/title", "attribute :title, :integer, )("),
        Edit.replace_entity_block("NoSuchModule/actions/read", "read"),
        Edit.replace_entity_block("#{name}/attributes/title", "attribute :title, :string",
          write: true
        ),
        Edit.replace_entity_block(
          "#{name}/attributes/title",
          "attribute :title, :string",
          write: true,
          expected_digest: "deadbeef"
        ),
        Edit.safe_delete_entity("#{name}/attributes/title"),
        Edit.safe_delete_entity("NoSuchModule/attributes/title"),
        Edit.replace_entity_block(nil, nil),
        Edit.replace_entity_block("#{name}/attributes/title", :not_a_string)
      ]

      for {:error, report} <- reports do
        assert is_binary(Jason.encode!(report))
      end
    end

    test "unresolvable name paths return structured errors" do
      {:error, report} = Edit.safe_delete_entity("NoSuchModule/attributes/title")
      assert report.error == "unresolvable_name_path"
      assert report.message =~ "no Ash module"
    end
  end

  defp strip_block(content, needle) do
    String.replace(content, needle, "")
  end
end
