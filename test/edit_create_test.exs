# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.EditCreateTest do
  use ExUnit.Case, async: false

  # Create/batch tests compile probe resources from temporary fixture copies
  # (module renamed, so the repo's own test resources are untouched), the
  # same discipline as AshAgentTools.EditTest. Serialized (async: false)
  # because the probes mutate the shared code namespace.

  alias AshAgentTools.Edit

  @post_fixture "test/support/post.ex"
  @module_prefix "AshAgentTools.Test.EditCreateProbe"

  setup do
    unique = System.unique_integer([:positive])
    module = Module.concat(["#{@module_prefix}#{unique}"])
    dir = Path.join(["tmp", "edit_probes", Integer.to_string(unique)])
    File.mkdir_p!(dir)
    path = Path.join(dir, "create_probe.ex")

    @post_fixture
    |> File.read!()
    |> String.replace("defmodule AshAgentTools.Test.Post do", "defmodule #{module} do")
    |> then(&File.write!(path, &1))

    compile!(path)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      File.rm_rf!(dir)
    end)

    %{
      module: module,
      path: path,
      dir: dir,
      name: module |> Module.split() |> Enum.join(".")
    }
  end

  defp compile!(path) do
    previous_debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)
    Code.compile_file(path)
    Code.put_compiler_option(:debug_info, previous_debug_info)
  end

  defp digest!(path), do: Edit.shape(path).digest

  # A skeleton resource with an `attributes` block only: no `actions`,
  # `calculations` or `relationships` block exists — the synthesis cases.
  defp skeleton!(dir, _name) do
    module = Module.concat(["#{@module_prefix}Skel#{System.unique_integer([:positive])}"])
    path = Path.join(dir, "skeleton.ex")

    """
    defmodule #{module} do
      use Ash.Resource, domain: AshAgentTools.Test.Domain

      attributes do
      end
    end
    """
    |> then(&File.write!(path, &1))

    compile!(path)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    %{module: module, path: path, name: module |> Module.split() |> Enum.join(".")}
  end

  describe "create_entity/3 — synthesis" do
    test "creates an actions section where none exists (synthesized block)", %{
      dir: dir,
      name: name
    } do
      %{module: module, path: path, name: skel_name} = skeleton!(dir, name)
      original = File.read!(path)

      {:ok, plan} =
        Edit.create_entity("#{skel_name}/actions", "update :check_in do accept [] end")

      assert plan.dry_run?
      assert plan.placement == :synthesized_section
      assert plan.name_path == "#{skel_name}/actions/check_in"
      assert File.read!(path) == original

      {:ok, report} =
        Edit.create_entity("#{skel_name}/actions", "update :check_in do accept [] end",
          write: true,
          expected_digest: plan.current_digest
        )

      assert report.applied?
      assert report.gate.compile == "ok"

      content = File.read!(path)
      refute content == original
      assert content =~ "actions do\n    update :check_in do\n      accept []\n    end\n  end"

      # the created entity is addressable after the gate
      assert {:ok, resolved} = AshAgentTools.resolve("#{skel_name}/actions/check_in")
      assert Path.expand(resolved.symbol.source.file) == Path.expand(path)
      assert resolved.module.module == module
    end

    test "synthesis lands after the last existing section block", %{dir: dir, name: name} do
      %{path: path, name: skel_name} = skeleton!(dir, name)

      {:ok, _} =
        Edit.create_entity("#{skel_name}/actions", "update :check_in do accept [] end",
          write: true,
          expected_digest: digest!(path)
        )

      content = File.read!(path)
      # the attributes block was the only section before; the new block
      # comes after it and before the module's final end
      assert content =~ "attributes do"
      assert content =~ "  end\n\n  actions do\n    update :check_in"
      assert String.trim_trailing(content) =~ "end"
    end
  end

  describe "create_entity/3 — populated and empty sections" do
    test "appends at the section tail of a populated section", %{path: path, name: name} do
      {:ok, plan} =
        Edit.create_entity("#{name}/attributes", "attribute :reviewed, :boolean, default: false")

      assert plan.placement == :section_tail

      {:ok, report} =
        Edit.create_entity("#{name}/attributes", "attribute :reviewed, :boolean, default: false",
          write: true,
          expected_digest: plan.current_digest
        )

      assert report.applied?
      assert File.read!(path) =~ "attribute :reviewed, :boolean, default: false"
      assert {:ok, _} = AshAgentTools.resolve("#{name}/attributes/reviewed")
    end

    test "anchors before and after an existing entity", %{name: name, path: path} do
      {:ok, _} =
        Edit.create_entity("#{name}/attributes", "attribute :alpha, :string",
          anchor: "#{name}/attributes/score",
          position: :before,
          write: true,
          expected_digest: digest!(path)
        )

      content = File.read!(path)
      assert content =~ "attribute :alpha, :string\n\n    attribute :score"

      {:ok, _} =
        Edit.create_entity("#{name}/attributes", "attribute :omega, :string",
          anchor: "#{name}/attributes/score",
          position: :after,
          write: true,
          expected_digest: digest!(path)
        )

      assert File.read!(path) =~
               "attribute :score, :integer, public?: true\n\n    attribute :omega"
    end

    test "inserts inside an existing but empty section block", %{dir: dir, name: name} do
      %{path: path, name: skel_name} = skeleton!(dir, name)

      # the skeleton ships `attributes do end` with nothing inside — a
      # section block present but empty, the case synthesis cannot cover
      {:ok, plan} =
        Edit.create_entity("#{skel_name}/attributes", "attribute :revival, :string")

      assert plan.placement == :inside_section_block

      {:ok, report} =
        Edit.create_entity("#{skel_name}/attributes", "attribute :revival, :string",
          write: true,
          expected_digest: plan.current_digest
        )

      assert report.applied?
      content = File.read!(path)
      assert content =~ "attributes do\n    attribute :revival, :string\n  end"
    end

    test "an anchor in another section is refused", %{name: name} do
      {:error, report} =
        Edit.create_entity("#{name}/attributes", "attribute :x, :string",
          anchor: "#{name}/actions/create"
        )

      assert report.error == "anchor_section_mismatch"
    end
  end

  describe "create_entity/3 — guards" do
    test "duplicate identifiers are refused with a pointer to the existing entity", %{
      name: name
    } do
      {:error, report} =
        Edit.create_entity("#{name}/attributes", "attribute :score, :integer")

      assert report.error == "duplicate_entity"
      assert report.existing_name_path == "#{name}/attributes/score"
      assert report.message =~ "already exists"
    end

    test "a duplicate against an earlier batch creation is refused", %{name: name, path: path} do
      ops = [
        %{
          "op" => "create_entity",
          "section_path" => "#{name}/attributes",
          "body" => "attribute :dupe, :string"
        },
        %{
          "op" => "create_entity",
          "section_path" => "#{name}/attributes",
          "body" => "attribute :dupe, :string"
        }
      ]

      {:error, report} = Edit.apply_batch(ops, write: true, expected_digest: digest!(path))

      assert report.error == "batch_aborted"
      assert report.detail.error == "duplicate_entity"
    end

    test "unknown dsl_paths are refused with the valid list", %{name: name} do
      {:error, report} = Edit.create_entity("#{name}/widgets", "widget :x")

      assert report.error == "unknown_section"
      assert report.message =~ "unknown dsl_path"
    end

    test "multi-entity bodies are refused" do
      {:error, report} =
        Edit.create_entity(
          "AshAgentTools.Test.Post/attributes",
          "attribute :a, :string\nattribute :b, :string"
        )

      assert report.error == "multiple_entities"
    end
  end

  describe "create_entity/3 — safety model" do
    test "dry-run touches nothing and hands back the digest", %{path: path, name: name} do
      before = File.read!(path)

      {:ok, plan} =
        Edit.create_entity("#{name}/attributes", "attribute :reviewed, :boolean, default: false")

      assert plan.dry_run?
      assert plan.current_digest == digest!(path)
      assert File.read!(path) == before
    end

    test "stale digests refuse the write", %{name: name} do
      {:error, report} =
        Edit.create_entity("#{name}/attributes", "attribute :reviewed, :boolean",
          write: true,
          expected_digest: "deadbeef"
        )

      assert report.error == "stale_file"
    end

    test "a compile-breaking creation reverts the file", %{path: path, name: name} do
      original = File.read!(path)

      {:error, report} =
        Edit.create_entity("#{name}/attributes", "attribute :reviewed, :not_a_real_type",
          write: true,
          expected_digest: digest!(path)
        )

      assert report.error == "post_edit_gate_failed"
      assert report.reverted?
      assert File.read!(path) == original
    end

    test "error reports stay JSON-encodable", %{name: name} do
      reports = [
        Edit.create_entity(nil, "attribute :x, :string"),
        Edit.create_entity("#{name}/attributes", "attribute :x, )("),
        Edit.create_entity("#{name}/attributes", "attribute :score, :integer"),
        Edit.create_entity("#{name}/nope", "attribute :x, :string")
      ]

      for {:error, report} <- reports do
        assert is_binary(Jason.encode!(report))
      end
    end
  end

  describe "the formatter contract" do
    test "a format-clean file is reformatted whole after the edit", %{path: path, name: name} do
      # the fixture is format-clean; a deliberately un-formatted body is
      # normalized by the whole-file pass, not left dirty
      {:ok, plan} =
        Edit.create_entity("#{name}/attributes", "attribute :reviewed,:boolean, default: false")

      {:ok, report} =
        Edit.create_entity("#{name}/attributes", "attribute :reviewed,:boolean, default: false",
          write: true,
          expected_digest: plan.current_digest
        )

      assert report.formatted? == true
      refute Map.has_key?(report, :format_hint)
      # the formatter fixed the comma spacing our body skipped
      assert File.read!(path) =~ "attribute :reviewed, :boolean, default: false"
    end

    test "a dirty file is left as spliced and carries a format_hint", %{path: path, name: name} do
      # make the file not format-clean, outside the edit region
      dirty =
        String.replace(
          File.read!(path),
          "attribute :title, :string do",
          "attribute  :title,  :string  do"
        )

      File.write!(path, dirty)
      digest = digest!(path)

      {:ok, report} =
        Edit.create_entity("#{name}/attributes", "attribute :reviewed, :boolean",
          write: true,
          expected_digest: digest
        )

      assert report.formatted? == false
      assert report[:format_hint] == "run mix format"
      # our edit landed, the pre-existing noise was not "fixed"
      content = File.read!(path)
      assert content =~ "attribute :reviewed, :boolean"
      assert content =~ "attribute  :title,  :string  do"
    end
  end

  describe "apply_batch/2" do
    test "applies a mixed batch with one handshake and one write", %{name: name, path: path} do
      original = File.read!(path)
      digest = digest!(path)

      ops = [
        %{
          "op" => "create_entity",
          "section_path" => "#{name}/attributes",
          "body" => "attribute :standalone, :string"
        },
        %{
          "op" => "replace_entity_block",
          "name_path" => "#{name}/attributes/score",
          "body" => "attribute :score, :integer, allow_nil?: false"
        },
        %{
          "op" => "insert_after_entity",
          "name_path" => "#{name}/attributes/standalone",
          "body" => "attribute :after_standalone, :string"
        },
        %{
          "op" => "insert_after_entity",
          "name_path" => "#{name}/attributes/after_standalone",
          "body" => "attribute :chained, :string"
        }
      ]

      {:ok, report} = Edit.apply_batch(ops, write: true, expected_digest: digest)

      assert report.applied?
      assert report.op_count == 4
      assert length(report.ops) == 4
      assert report.combined_diff =~ "-     attribute :score, :integer, public?: true"
      assert report.combined_diff =~ "+     attribute :score, :integer, allow_nil?: false"
      assert report.new_digest != digest

      content = File.read!(path)
      assert content =~ "attribute :standalone, :string"
      assert content =~ "attribute :score, :integer, allow_nil?: false"
      assert content =~ "attribute :after_standalone, :string"
      assert content =~ "attribute :chained, :string"
      refute content == original
    end

    test "a later op can anchor on an earlier creation", %{name: name, path: path} do
      digest = digest!(path)

      ops = [
        %{
          "op" => "create_entity",
          "section_path" => "#{name}/attributes",
          "body" => "attribute :head_attr, :string"
        },
        %{
          "op" => "insert_after_entity",
          "name_path" => "#{name}/attributes/head_attr",
          "body" => "attribute :tail_attr, :string"
        }
      ]

      {:ok, _} = Edit.apply_batch(ops, write: true, expected_digest: digest)

      content = File.read!(path)
      assert content =~ "attribute :head_attr, :string\n\n    attribute :tail_attr, :string"
    end

    test "a bad op mid-batch aborts everything, byte-identical file", %{name: name, path: path} do
      before = File.read!(path)
      digest = digest!(path)

      ops = [
        %{
          "op" => "create_entity",
          "section_path" => "#{name}/attributes",
          "body" => "attribute :standalone, :string"
        },
        %{
          "op" => "replace_entity_block",
          "name_path" => "#{name}/attributes/missing_thing",
          "body" => "attribute :score, :integer"
        }
      ]

      {:error, report} = Edit.apply_batch(ops, write: true, expected_digest: digest)

      assert report.error == "batch_aborted"
      assert report.index == 1
      assert report.detail.error == "unresolvable_name_path"
      assert report.applied? == false
      assert File.read!(path) == before
    end

    test "a failed gate reverts the whole batch", %{name: name, path: path} do
      before = File.read!(path)
      digest = digest!(path)

      ops = [
        %{
          "op" => "create_entity",
          "section_path" => "#{name}/attributes",
          "body" => "attribute :standalone, :string"
        },
        %{
          "op" => "replace_entity_block",
          "name_path" => "#{name}/attributes/score",
          "body" => "attribute :score, :not_a_real_type"
        }
      ]

      {:error, report} = Edit.apply_batch(ops, write: true, expected_digest: digest)

      assert report.error == "post_edit_gate_failed"
      assert report.reverted?
      assert File.read!(path) == before
    end

    test "a dry-run plans every op and touches nothing", %{name: name, path: path} do
      before = File.read!(path)

      ops = [
        %{
          "op" => "create",
          "section_path" => "#{name}/attributes",
          "body" => "attribute :x1, :string"
        },
        %{
          "op" => "insert_after_entity",
          "name_path" => "#{name}/attributes/x1",
          "body" => "attribute :x2, :string"
        }
      ]

      {:ok, report} = Edit.apply_batch(ops)

      assert report.dry_run?
      assert report.applied? == false
      assert length(report.ops) == 2
      assert File.read!(path) == before
    end

    test "ops across two files are refused", %{name: name, path: path} do
      ops = [
        %{
          "op" => "replace_entity_block",
          "name_path" => "#{name}/attributes/score",
          "body" => "attribute :score, :integer"
        },
        %{
          "op" => "replace_entity_block",
          "name_path" => "AshAgentTools.Test.Post/attributes/score",
          "body" => "attribute :score, :integer"
        }
      ]

      {:error, report} = Edit.apply_batch(ops, write: true, expected_digest: digest!(path))

      assert report.error == "batch_multiple_files"
    end

    test "unknown ops and empty batches are structured errors" do
      {:error, report} = Edit.apply_batch([%{"op" => "detonate"}])
      assert report.error == "unknown_operation"

      {:error, report} = Edit.apply_batch([])
      assert report.error == "empty_batch"
    end
  end
end
