# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.CodeSubjects do
  @moduledoc """
  Code units as judgment subjects: modules, functions, DSL entities, doc
  paragraphs, diff hunks and commit messages, each with a stable address,
  a `path:line` location and a state digest.

  A question judged over code (a prose standard such as "policy checks
  never query") needs three things from its subject: an address that
  survives unrelated edits, so a recorded fact keeps pointing at the same
  unit; a digest of exactly what the question saw, so the fact goes stale
  when that changes (RFC S1-24 §7.4 normative 2); and a location a person
  can click. This module supplies all three as plain, JSON-encodable maps.
  Extraction is syntactic (Sourceror over the file text), so it works on
  any repository, loaded or not.

  ## Subjects

  Every subject carries:

    * `id` — `"<repository>:<path>#<name_path>"`, the key the facts table
      stores (see `subject_term/2`)
    * `repository`, `path` (relative to the repository root), `name_path`
    * `kind` — `:module | :function | :dsl_entity | :doc_paragraph |
      :diff_hunk | :commit_message`
    * `line` — where the unit starts (the `def`, the DSL call, the first
      line of the paragraph), and `location`, the clickable
      `"path:line"`
    * `span` — `%{start_line, end_line}`, the lines `text` covers (leading
      comments included)
    * `text` — the unit's source, with its common indentation removed
    * `module` (the enclosing module, when there is one), `parent` (the
      enclosing unit's name path), and `context` (see below)

  Name paths:

  | kind | name path |
  |---|---|
  | module | `MyApp.Accounts.User` |
  | function | `MyApp.Accounts.User.full_name/1` (all clauses of the name/arity) |
  | DSL entity | `MyApp.Accounts.User/actions/read`, `.../policies/policy[1]` |
  | doc paragraph | `MyApp.User@moduledoc[0]`, `MyApp.User.full_name/1@doc[2]`; in Markdown, the heading path: `Environment > Postgres[1]` |
  | diff hunk | `<enclosing name path>~hunk[0]` |
  | commit message | `commit:<sha>` |

  DSL entity paths use the `AshAgentTools.NamePath` spelling for the core
  Ash sections (`Resource/actions/read`, `Resource/policies/policy[0]`).
  Line numbers are never part of an address or a digest: editing one
  function moves the lines of the functions below it and changes neither
  their addresses nor their digests.

  ## Projections and digests

  A question declares what it sees. The projection is the unit's text plus
  the context the question declares, chosen from:

    * `:module_header` — the enclosing `defmodule` line and its `use`,
      `import`, `alias`, `require` and `@behaviour` statements
    * `:moduledoc` — the enclosing module's `@moduledoc`
    * `{:section, :policies}` — the enclosing module's DSL section of that
      name (any section: `:actions`, `:attributes`, `:postgres`, ...)
    * `:module` — the whole enclosing module

  `state/2` builds that projection and `digest/2` digests it with
  `AshJudgments.Registry.Canonical`, the digest a recorded judgment's
  `state_digest` uses, so a fact's `subject_state_digest` and the unit's
  current digest compare directly. `current_digests/3` produces the
  `:current_digests` map `AshJudgments.Query` reads: a fact whose digest
  differs reads `:stale`.

  The context a question declares must have been captured at extraction:
  pass `context: [...]` to `scan/2` (the union over the questions you
  will run). `AshAgentTools.CodeSubjects.Projection` turns a context list
  into the `state_projection` module a declared question names.

  Digests need the optional `ash_judgments` dependency; extraction,
  locations and chunking do not.

  ## Chunking

  `chunk/3` splits a subject whose projection would not fit the decision
  model's context (1,024 tokens by default, less a reserve for the
  question and the answer) into line-aligned chunks. Each chunk is a
  subject of its own (`<id>~chunk[i]`) with its own location and digest.

  ## Examples

      iex> source = "defmodule Demo do\\n  def hello(name), do: \\"hi \\" <> name\\nend\\n"
      iex> {:ok, subjects} = AshAgentTools.CodeSubjects.from_source(source, "lib/demo.ex", repository: "demo")
      iex> Enum.map(subjects, &{&1.kind, &1.name_path, &1.location})
      [{:module, "Demo", "lib/demo.ex:1"}, {:function, "Demo.hello/1", "lib/demo.ex:2"}]
  """

  alias AshAgentTools.Availability
  alias AshAgentTools.CodeSubjects.DiffHunks
  alias AshAgentTools.CodeSubjects.ElixirSource
  alias AshAgentTools.CodeSubjects.Markdown
  alias AshAgentTools.CodeSubjects.Text

  @kinds [:module, :function, :dsl_entity, :doc_paragraph, :diff_hunk, :commit_message]

  @default_type "AshAgentTools.CodeSubjects"

  @skip_dirs ~w(_build deps node_modules cover doc tmp)

  @default_max_tokens 1024
  @default_reserve_tokens 256

  @typedoc "A code subject: a plain map (see the module doc for its fields)."
  @type subject :: map()

  @typedoc """
  A declared context: `:module_header`, `:moduledoc`, `:module`, or
  `{:section, name}`. The string spellings `"module_header"`,
  `"moduledoc"`, `"module"` and `"section:<name>"` are accepted too.
  """
  @type context_spec :: :module_header | :moduledoc | :module | {:section, atom() | String.t()}

  @typedoc "A projection: a list of context specs, or a projection module."
  @type projection :: [context_spec() | String.t()] | module()

  @doc "The subject kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  # -- extraction --------------------------------------------------------------

  @doc """
  Extracts the subjects of every Elixir (`.ex`, `.exs`) and Markdown
  (`.md`) file under `root`.

  Options:

    * `:repository` — the repository name in every id (default: the
      basename of `root`)
    * `:paths` — files or directories to scan, relative to `root`
      (default `["."]`). Directory walks skip hidden entries and
      `#{Enum.join(@skip_dirs, ", ")}`
    * `:context` — the context specs to capture (see the module doc)
    * `:kinds` — keep only these kinds

  Returns `%{repository, subjects, skipped}`; `skipped` lists the files
  that could not be read or parsed, with the reason.
  """
  @spec scan(Path.t(), keyword()) :: %{
          repository: String.t(),
          subjects: [subject()],
          skipped: [map()]
        }
  def scan(root, opts \\ []) do
    root = Path.expand(root)
    opts = Keyword.put_new(opts, :repository, Path.basename(root))
    paths = Keyword.get(opts, :paths, ["."])

    {subjects, skipped} =
      paths
      |> Enum.flat_map(&files(root, &1))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn relative, {subjects, skipped} ->
        with {:ok, source} <- File.read(Path.join(root, relative)),
             {:ok, found} <- from_source(source, relative, opts) do
          {[found | subjects], skipped}
        else
          {:error, reason} ->
            {subjects, [%{path: relative, reason: format_reason(reason)} | skipped]}
        end
      end)

    %{
      repository: opts[:repository],
      subjects: subjects |> Enum.reverse() |> List.flatten(),
      skipped: Enum.reverse(skipped)
    }
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp files(root, relative) do
    absolute = Path.join(root, relative)

    cond do
      File.regular?(absolute) -> [Path.relative_to(Path.expand(absolute), root)]
      File.dir?(absolute) -> walk(root, Path.expand(absolute))
      true -> []
    end
  end

  defp walk(root, dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(String.starts_with?(&1, ".") or &1 in @skip_dirs))
        |> Enum.flat_map(fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) -> walk(root, path)
            Path.extname(entry) in [".ex", ".exs", ".md"] -> [Path.relative_to(path, root)]
            true -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Extracts the subjects of one file's source. `path` is the file's path
  relative to the repository root; a `.md` path is read as Markdown,
  anything else as Elixir.

  Takes the `:repository`, `:context` and `:kinds` options of `scan/2`.
  Returns `{:error, reason}` when Elixir source does not parse.
  """
  @spec from_source(String.t(), String.t(), keyword()) ::
          {:ok, [subject()]} | {:error, String.t()}
  def from_source(source, path, opts \\ []) when is_binary(source) and is_binary(path) do
    context = normalize_context(Keyword.get(opts, :context, []))

    result =
      if Path.extname(path) == ".md" do
        {:ok, Markdown.extract(source), %{}}
      else
        ElixirSource.extract(source, path)
      end

    case result do
      {:ok, units, modules} ->
        {:ok,
         units
         |> Enum.map(&finalize(&1, path, opts, context, modules))
         |> filter_kinds(opts[:kinds])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extracts one subject per hunk of a unified diff (`git diff` output).

  A hunk is located at its first added line in the post-image. Pass
  `:root` (the post-image checkout) to address each hunk under the unit
  that encloses it (`MyApp.Post.publish/1~hunk[0]`) and to capture its
  module context; without it, hunks are addressed by their order in the
  file (`~hunk[0]`).

  Takes the `:repository`, `:context` and `:kinds` options of `scan/2`.
  """
  @spec from_diff(String.t(), keyword()) :: [subject()]
  def from_diff(diff, opts \\ []) when is_binary(diff) do
    context = normalize_context(Keyword.get(opts, :context, []))

    opts =
      Keyword.put_new(opts, :repository, opts[:root] && Path.basename(Path.expand(opts[:root])))

    diff
    |> DiffHunks.parse()
    |> Enum.reject(&is_nil(&1.path))
    |> Enum.group_by(& &1.path)
    |> Enum.sort_by(fn {path, _} -> path end)
    |> Enum.flat_map(fn {path, hunks} ->
      {enclosing_units, modules} = post_image(opts[:root], path)

      {subjects, _counts} =
        Enum.map_reduce(hunks, %{}, fn hunk, counts ->
          enclosing = innermost(enclosing_units, hunk.line)
          prefix = if enclosing, do: enclosing.name_path, else: ""
          index = Map.get(counts, prefix, 0)

          unit =
            hunk
            |> Map.put(:name_path, "#{prefix}~hunk[#{index}]")
            |> Map.put(:module, enclosing && enclosing.module)
            |> Map.put(:parent, enclosing && enclosing.name_path)

          {finalize(unit, path, opts, context, modules), Map.put(counts, prefix, index + 1)}
        end)

      subjects
    end)
    |> filter_kinds(opts[:kinds])
  end

  defp post_image(nil, _path), do: {[], %{}}

  defp post_image(root, path) do
    with true <- Path.extname(path) in [".ex", ".exs"],
         {:ok, source} <- File.read(Path.join(root, path)),
         {:ok, units, modules} <- ElixirSource.extract(source, path) do
      {Enum.filter(units, &(&1.kind in [:module, :function, :dsl_entity])), modules}
    else
      _ -> {[], %{}}
    end
  end

  @doc """
  One subject for a commit message.

  Options:

    * `:repository` (required)
    * `:sha` — the commit (`commit:<sha>`; `commit:pending` without one)
    * `:path` — the file holding the message, relative to the repository
      root, for a message not yet committed (`.git/COMMIT_EDITMSG` in a
      `commit-msg` hook). With a path the location is `path:line`;
      without one it is the sha
    * `:web_base` — e.g. `"https://github.com/owner/repo"`; adds a
      `url` to the commit page

  Git's trailing comment block (lines starting with `#`) is dropped.
  """
  @spec from_commit_message(String.t(), keyword()) :: subject()
  def from_commit_message(message, opts) when is_binary(message) do
    repository = Keyword.fetch!(opts, :repository)
    sha = opts[:sha]
    path = opts[:path]
    text = message |> Text.lines() |> strip_commit_comments() |> Enum.join("\n")
    end_line = max(length(Text.lines(text)), 1)
    name_path = "commit:#{sha || "pending"}"

    %{
      id: id(repository, path, name_path),
      repository: repository,
      path: path,
      name_path: name_path,
      kind: :commit_message,
      line: 1,
      span: %{start_line: 1, end_line: end_line},
      location: if(path, do: "#{path}:1", else: sha || "pending"),
      text: text,
      module: nil,
      parent: nil,
      sha: sha,
      context: blank_context(normalize_context(Keyword.get(opts, :context, [])))
    }
    |> put_url(opts[:web_base], sha)
  end

  defp strip_commit_comments(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))
    |> Enum.reverse()
    |> Enum.map(&String.trim_trailing/1)
  end

  defp put_url(subject, nil, _sha), do: subject
  defp put_url(subject, _web_base, nil), do: subject

  defp put_url(subject, web_base, sha),
    do: Map.put(subject, :url, "#{String.trim_trailing(web_base, "/")}/commit/#{sha}")

  @doc """
  The commit-message subjects of a revision range in the git repository at
  `root` (`"main..HEAD"`, `"-20"`, a single sha with `"-1 <sha>"`).

  Runs `git log` (read-only). Takes the options of
  `from_commit_message/2`; `:repository` defaults to the basename of
  `root`. Returns `{:error, output}` when git fails.
  """
  @spec from_commits(Path.t(), String.t(), keyword()) :: {:ok, [subject()]} | {:error, String.t()}
  def from_commits(root, revisions, opts \\ []) when is_binary(revisions) do
    root = Path.expand(root)
    opts = Keyword.put_new(opts, :repository, Path.basename(root))
    args = ["-C", root, "log", "--format=%H%x00%B%x1e"] ++ OptionParser.split(revisions)

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} ->
        subjects =
          output
          |> String.split("\x1e", trim: true)
          |> Enum.map(&String.trim_leading/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn record ->
            [sha, message] = String.split(record, "\0", parts: 2)
            from_commit_message(message, Keyword.merge(opts, sha: sha, path: nil))
          end)

        {:ok, subjects}

      {output, _status} ->
        {:error, String.trim(output)}
    end
  end

  defp finalize(unit, path, opts, context, modules) do
    repository = opts[:repository] || "."
    module_info = unit[:module] && Map.get(modules, unit.module)

    unit
    |> Map.merge(%{
      id: id(repository, path, unit.name_path),
      repository: repository,
      path: path,
      location: "#{path}:#{unit.line}",
      context: capture_context(context, module_info)
    })
    |> Map.put_new(:module, nil)
    |> Map.put_new(:parent, nil)
  end

  defp id(repository, path, name_path), do: "#{repository}:#{path}##{name_path}"

  defp filter_kinds(subjects, nil), do: subjects
  defp filter_kinds(subjects, kinds), do: Enum.filter(subjects, &(&1.kind in kinds))

  # -- context -----------------------------------------------------------------

  defp capture_context(keys, nil), do: blank_context(keys)

  defp capture_context(keys, info) do
    Map.new(keys, fn
      "module_header" -> {"module_header", info.header}
      "moduledoc" -> {"moduledoc", info.moduledoc}
      "module" -> {"module", info.text}
      "section:" <> name = key -> {key, Map.get(info.sections, name)}
    end)
  end

  defp blank_context(keys), do: Map.new(keys, &{&1, nil})

  @doc false
  # Context specs as their canonical string keys (the keys of a subject's
  # `context` map and of the projected state's `"context"`).
  @spec normalize_context(projection()) :: [String.t()]
  def normalize_context(module) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__code_subject_context__, 0) do
      module.__code_subject_context__()
    else
      raise ArgumentError,
            "#{inspect(module)} is not a code-subject projection" <>
              " (use AshAgentTools.CodeSubjects.Projection)"
    end
  end

  def normalize_context(specs) when is_list(specs) do
    specs |> Enum.map(&context_key/1) |> Enum.uniq() |> Enum.sort()
  end

  defp context_key(:module_header), do: "module_header"
  defp context_key(:moduledoc), do: "moduledoc"
  defp context_key(:module), do: "module"
  defp context_key({:section, name}) when is_atom(name), do: "section:#{name}"
  defp context_key({:section, name}) when is_binary(name), do: "section:#{name}"
  defp context_key(key) when key in ["module_header", "moduledoc", "module"], do: key
  defp context_key("section:" <> name = key) when name != "", do: key

  defp context_key(other) do
    raise ArgumentError,
          "unknown code-subject context #{inspect(other)}: expected :module_header," <>
            " :moduledoc, :module or {:section, name}"
  end

  # -- projection and digest ------------------------------------------------------

  @doc """
  The projected state a question with the given projection sees for
  `subject`: string-keyed and JSON-encodable.

      %{
        "kind" => "function",
        "repository" => "...", "path" => "lib/...", "name_path" => "...",
        "text" => "def ...",
        "context" => %{"section:policies" => "policies do ... end"},  # when declared
        "chunk" => %{"index" => 0, "of" => 2}                          # chunks only
      }

  Accepts subjects with atom or string keys (a subject that round-tripped
  through JSON or an action input). Raises `ArgumentError` when the
  projection declares context the subject was extracted without.
  """
  @spec state(subject(), projection()) :: map()
  def state(subject, projection \\ []) do
    keys = normalize_context(projection)

    base = %{
      "kind" => to_string(field(subject, :kind)),
      "repository" => field(subject, :repository),
      "path" => field(subject, :path),
      "name_path" => field(subject, :name_path),
      "text" => field(subject, :text)
    }

    base
    |> put_state_context(subject, keys)
    |> put_state_chunk(field(subject, :chunk))
  end

  defp put_state_context(state, _subject, []), do: state

  defp put_state_context(state, subject, keys) do
    captured = field(subject, :context) || %{}

    context =
      Map.new(keys, fn key ->
        case Map.fetch(captured, key) do
          {:ok, value} ->
            {key, value}

          :error ->
            raise ArgumentError,
                  "subject #{inspect(field(subject, :id))} was extracted without the" <>
                    " #{inspect(key)} context; pass it in `context:` when extracting"
        end
      end)

    Map.put(state, "context", context)
  end

  defp put_state_chunk(state, nil), do: state

  defp put_state_chunk(state, chunk),
    do: Map.put(state, "chunk", %{"index" => field(chunk, :index), "of" => field(chunk, :of)})

  @doc """
  The declared shape of a projection's state, as data: what a question's
  `state_shape` declares, so a change to the context a question sees is a
  change to the question's identity (RFC S1-24 §3.2).
  """
  @spec shape(projection()) :: map()
  def shape(projection \\ []) do
    base = %{
      "kind" => "string",
      "repository" => "string",
      "path" => "string | null",
      "name_path" => "string",
      "text" => "string",
      "chunk" => "absent | {index: integer, of: integer}"
    }

    case normalize_context(projection) do
      [] -> base
      keys -> Map.put(base, "context", Map.new(keys, &{&1, "string | null"}))
    end
  end

  @doc """
  The digest of the subject's projected state: `"sha256:<hex>"`, computed
  exactly as `AshJudgments` computes a judgment's `state_digest`, so it
  compares directly with a fact's `subject_state_digest`.

  Needs the optional `ash_judgments` dependency.
  """
  @spec digest(subject(), projection()) :: String.t()
  def digest(subject, projection \\ []) do
    Availability.ensure_active!(:ash_judgments)
    AshAgentTools.CodeSubjects.Digest.digest(state(subject, projection))
  end

  @doc """
  The `:current_digests` map `AshJudgments.Query` takes, for one
  question's projection: `%{subject_term => digest}`.

  `opts` are passed to `subject_term/2` (`:type`).
  """
  @spec current_digests([subject()], projection(), keyword()) :: %{map() => String.t()}
  def current_digests(subjects, projection \\ [], opts \\ []) do
    Map.new(subjects, &{subject_term(&1, opts), digest(&1, projection)})
  end

  @doc """
  The composite subject term the facts table stores (RFC S1-24 §7.4):
  `%{"type" => type, "id" => id}`.

  `:type` defaults to `#{inspect(@default_type)}`; a host that declares
  its questions on its own code-unit resource passes that resource's
  name.
  """
  @spec subject_term(subject(), keyword()) :: %{String.t() => String.t()}
  def subject_term(subject, opts \\ []) do
    %{"type" => Keyword.get(opts, :type, @default_type), "id" => field(subject, :id)}
  end

  # -- chunking ---------------------------------------------------------------------

  @doc """
  Splits a subject whose projected state does not fit the decision
  model's context into line-aligned chunk subjects; returns `[subject]`
  when it fits.

  Options:

    * `:max_tokens` — the model's context (default #{@default_max_tokens})
    * `:reserve_tokens` — kept free for the question and the answer
      (default #{@default_reserve_tokens})
    * `:token_count` — a `(String.t() -> non_neg_integer())` counter;
      the default estimates one token per three bytes of the JSON-encoded
      state, which over-counts for typical code and prose

  Each chunk is `<id>~chunk[i]` / `<name_path>~chunk[i]` with its own
  `line`, `span`, `location` and `chunk: %{index, of, parent_id}`. Raises
  `ArgumentError` when the declared context alone leaves no room for text.
  """
  @spec chunk(subject(), projection(), keyword()) :: [subject()]
  def chunk(subject, projection \\ [], opts \\ []) do
    budget =
      Keyword.get(opts, :max_tokens, @default_max_tokens) -
        Keyword.get(opts, :reserve_tokens, @default_reserve_tokens)

    count = Keyword.get(opts, :token_count, &estimate_tokens/1)

    if count.(Jason.encode!(state(subject, projection))) <= budget do
      [subject]
    else
      split(subject, projection, budget, count)
    end
  end

  @doc false
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text), do: div(byte_size(text) + 2, 3)

  defp split(subject, projection, budget, count) do
    # Measure each candidate as the chunk's full projected state, with the
    # widest chunk address and counters it could carry, so a chunk that
    # fits here fits as emitted.
    probe =
      Map.merge(subject, %{
        name_path: "#{subject.name_path}~chunk[999999]",
        chunk: %{index: 999_999, of: 999_999}
      })

    measure = fn text -> count.(Jason.encode!(state(Map.put(probe, :text, text), projection))) end

    if measure.("") > budget do
      raise ArgumentError,
            "the declared context of #{inspect(subject.id)} alone exceeds the" <>
              " #{budget}-token budget; declare less context or raise :max_tokens"
    end

    fits? = &(measure.(&1) <= budget)

    pieces =
      subject.text
      |> Text.lines()
      |> Enum.with_index()
      |> pack(fits?)

    total = length(pieces)

    pieces
    |> Enum.with_index()
    |> Enum.map(fn {{offset, last_offset, text}, index} ->
      line = chunk_line(subject, offset)
      end_line = chunk_line(subject, last_offset)

      Map.merge(subject, %{
        id: "#{subject.id}~chunk[#{index}]",
        name_path: "#{subject.name_path}~chunk[#{index}]",
        text: text,
        line: line,
        span: %{start_line: line, end_line: end_line},
        location: chunk_location(subject, line),
        chunk: %{index: index, of: total, parent_id: subject.id}
      })
    end)
  end

  # Greedy line packing: each piece takes lines until the next would
  # overflow. A single line that overflows on its own is split by
  # halving.
  defp pack(indexed_lines, fits?) do
    {pieces, current} =
      Enum.reduce(indexed_lines, {[], []}, fn {line, offset}, {pieces, current} ->
        candidate = [{offset, line} | current]

        cond do
          fits?.(join(candidate)) -> {pieces, candidate}
          current == [] -> {Enum.reverse(split_line(line, offset, fits?)) ++ pieces, []}
          fits?.(line) -> {[piece(current) | pieces], [{offset, line}]}
          true -> {Enum.reverse(split_line(line, offset, fits?)) ++ [piece(current) | pieces], []}
        end
      end)

    pieces = if current == [], do: pieces, else: [piece(current) | pieces]
    Enum.reverse(pieces)
  end

  defp join(reversed), do: reversed |> Enum.reverse() |> Enum.map_join("\n", &elem(&1, 1))

  defp piece([{last, _} | _] = reversed) do
    [{first, _} | _] = Enum.reverse(reversed)
    {first, last, join(reversed)}
  end

  defp split_line(line, offset, fits?) do
    if fits?.(line) or String.length(line) <= 1 do
      [{offset, offset, line}]
    else
      half = div(String.length(line), 2)
      {left, right} = String.split_at(line, half)
      split_line(left, offset, fits?) ++ split_line(right, offset, fits?)
    end
  end

  # A hunk's text holds removed lines, which are no post-image lines, so
  # its chunks keep the hunk's own line. Every other kind's text maps line
  # for line onto its span.
  defp chunk_line(%{kind: :diff_hunk} = subject, _offset), do: subject.line
  defp chunk_line(subject, offset), do: subject.span.start_line + offset

  defp chunk_location(%{path: nil} = subject, _line), do: subject.location
  defp chunk_location(subject, line), do: "#{subject.path}:#{line}"

  # -- roll-up ---------------------------------------------------------------------

  @doc """
  Rolls the three-valued statuses of a unit's chunks up to the unit.

  Each status is what `AshJudgments.Query.status/4` returns for one chunk
  (`{:in, fact}`, `{:out, fact}`, `{:unknown, reason}`) or the bare
  `:in` / `:out`. `mode` says how the chunks combine:

    * `:any` — the predicate holds of the unit when it holds of any chunk
      ("this function contains a policy check that queries"): `:in` if any
      chunk is in, `:out` only when every chunk is out
    * `:all` — the predicate holds only when it holds of every chunk
      ("every paragraph says the thing first"): `:out` if any chunk is out,
      `:in` only when every chunk is in

  Anything else is `{:unknown, reasons}`, with the chunks' unknown reasons:
  an unknown chunk never folds into either side.

      iex> AshAgentTools.CodeSubjects.roll_up([:out, {:unknown, :stale}, :in], :any)
      :in
      iex> AshAgentTools.CodeSubjects.roll_up([:out, {:unknown, :stale}], :any)
      {:unknown, [:stale]}
      iex> AshAgentTools.CodeSubjects.roll_up([:in, :in], :all)
      :in
  """
  @spec roll_up([term()], :any | :all) :: :in | :out | {:unknown, [atom()]}
  def roll_up(statuses, mode) when mode in [:any, :all] and is_list(statuses) do
    readings = Enum.map(statuses, &reading/1)
    {deciding, other} = if mode == :any, do: {:in, :out}, else: {:out, :in}
    combine(readings, deciding, other)
  end

  defp combine([], _deciding, _other), do: {:unknown, [:no_fact]}

  defp combine(readings, deciding, other) do
    unknowns = for {:unknown, reason} <- readings, do: reason

    cond do
      deciding in readings -> deciding
      unknowns == [] and Enum.all?(readings, &(&1 == other)) -> other
      true -> {:unknown, unknowns}
    end
  end

  defp reading(:in), do: :in
  defp reading(:out), do: :out
  defp reading({:in, _fact}), do: :in
  defp reading({:out, _fact}), do: :out
  defp reading({:unknown, reason}), do: {:unknown, reason}

  # -- locations ------------------------------------------------------------------

  @doc """
  The innermost module, function or DSL entity subject containing
  `path:line`, or `nil`. Maps a line-addressed finding (a laws-judge hit,
  a compiler warning) onto the subject it is about.
  """
  @spec locate([subject()], String.t(), pos_integer()) :: subject() | nil
  def locate(subjects, path, line) do
    subjects
    |> Enum.filter(&(&1.path == path and &1.kind in [:module, :function, :dsl_entity]))
    |> innermost(line)
  end

  defp innermost(units, line) do
    units
    |> Enum.filter(&(&1.span.start_line <= line and line <= &1.span.end_line))
    |> Enum.min_by(&{&1.span.end_line - &1.span.start_line, -kind_depth(&1.kind)}, fn -> nil end)
  end

  defp kind_depth(:module), do: 0
  defp kind_depth(_kind), do: 1

  @doc """
  Finds a subject again in the current source under `root`, by its path
  and name path: `{:ok, subject}` with today's lines, or
  `{:error, :not_found}` when the unit is gone. Takes the options of
  `from_source/3`; `:repository` defaults to the subject's.

  Diff hunks and commit messages are not re-extracted from a file
  (`{:error, :not_file_backed}`).
  """
  @spec resolve(Path.t(), subject(), keyword()) ::
          {:ok, subject()} | {:error, :not_found | :not_file_backed | String.t()}
  def resolve(root, subject, opts \\ []) do
    kind = field(subject, :kind)
    path = field(subject, :path)

    if kind in [:diff_hunk, :commit_message, "diff_hunk", "commit_message"] or is_nil(path) do
      {:error, :not_file_backed}
    else
      opts = Keyword.put_new(opts, :repository, field(subject, :repository))

      with {:ok, source} <- File.read(Path.join(Path.expand(root), path)),
           {:ok, subjects} <- from_source(source, path, opts) do
        case Enum.find(subjects, &(&1.name_path == field(subject, :name_path))) do
          nil -> {:error, :not_found}
          found -> {:ok, found}
        end
      else
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, format_reason(reason)}
      end
    end
  end

  # -- helpers --------------------------------------------------------------------

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_other, _key), do: nil
end
