# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Gate.Request do
  @moduledoc """
  The gate's request contract, normalised from what each harness sends.

      %{
        harness: "claude_code" | "opencode" | String.t(),
        tool: "bash" | "edit" | "write" | "read" | String.t(),
        command: String.t() | nil,
        paths: [String.t()],
        cwd: String.t() | nil,
        repo: %{root: String.t() | nil, kind: String.t() | nil},
        targets: [%{path: String.t(), kind: String.t() | nil}],
        session_id: String.t() | nil
      }

  `targets` are the `paths` as the rules see them: each relative to its own
  repository's root (absolute when it is in none), with that repository's
  kind.

  Three shapes are accepted, told apart by their keys:

    * Claude Code's `PreToolUse` hook input (`hook_event_name`, `tool_name`,
      `tool_input`, `cwd`, `session_id`);
    * opencode's `tool.execute.before` arguments as the bundled plugin posts
      them (`harness: "opencode"`, `tool`, `sessionID`, `args`, `directory`);
    * the contract itself, with string keys (`tool` and the rest).

  Tool names are lower-cased and the editing tools fold into `"edit"`
  (`MultiEdit`, `NotebookEdit`, opencode's `patch`), so one table answers
  both harnesses.

  `repo` is the repository the call acts on: for a shell command, the
  directory of a leading `cd DIR &&` or a `git -C DIR`, else `cwd`; for a
  path, the path's own repository (see `repo_for/2`). Its `kind` comes from
  the repository's git remotes and the host's `.agents/gate.json`:

      {"version": 1,
       "first_party": ["github\\\\.com[:/]example/"],
       "private": [],
       "community_fork": []}

  A repository with a remote named `upstream` is a `"community_fork"`.
  Otherwise its `origin` URL is matched against `community_fork`, then
  `private`, then `first_party` patterns (regular expressions). Anything else
  is unclassified: `kind` is `nil`, and the rules decide what an unclassified
  repository may do. Nothing is written.
  """

  @edit_tools ~w(edit multiedit notebookedit patch apply_patch)

  @typedoc "A normalised gate request."
  @type t :: %{
          harness: String.t(),
          tool: String.t(),
          command: String.t() | nil,
          paths: [String.t()],
          cwd: String.t() | nil,
          repo: %{root: String.t() | nil, kind: String.t() | nil},
          targets: [%{path: String.t(), kind: String.t() | nil}],
          session_id: String.t() | nil
        }

  @doc """
  Normalises a harness payload (string keys, as decoded from JSON) into the
  request contract. `config` is the host's `.agents/gate.json`, decoded.
  """
  @spec normalize(map(), map()) :: t()
  def normalize(payload, config \\ %{})

  def normalize(%{"hook_event_name" => _, "tool_name" => tool} = payload, config) do
    input = map_or_empty(payload["tool_input"])

    build(
      "claude_code",
      tool,
      input["command"],
      [input["file_path"], input["notebook_path"]],
      payload["cwd"],
      payload["session_id"],
      config
    )
  end

  def normalize(%{"harness" => "opencode", "tool" => tool} = payload, config) do
    args = map_or_empty(payload["args"])

    build(
      "opencode",
      tool,
      args["command"],
      [args["filePath"] | patch_paths(args["patchText"])],
      args["workdir"] || payload["directory"],
      payload["sessionID"],
      config
    )
  end

  def normalize(%{"tool" => tool} = payload, config) do
    build(
      payload["harness"] || "unknown",
      tool,
      payload["command"],
      List.wrap(payload["paths"]),
      payload["cwd"],
      payload["session_id"],
      config
    )
  end

  def normalize(_payload, config), do: build("unknown", "", nil, [], nil, nil, config)

  defp build(harness, tool, command, paths, cwd, session_id, config) do
    cwd = string_or_nil(cwd)
    command = string_or_nil(command)
    paths = paths |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()
    repo = repo_for(subject_dir(command, cwd), config)

    %{
      harness: to_string(harness),
      tool: tool_name(tool),
      command: command,
      paths: paths,
      cwd: cwd,
      repo: repo,
      targets: Enum.map(paths, &target(&1, cwd, repo, config)),
      session_id: string_or_nil(session_id)
    }
  end

  defp target(path, cwd, repo, config) do
    absolute = expand(path, cwd)

    repo =
      if repo.root && String.starts_with?(absolute, repo.root <> "/"),
        do: repo,
        else: repo_for(Path.dirname(absolute), config)

    case repo.root do
      nil -> %{path: absolute, kind: nil}
      root -> %{path: Path.relative_to(absolute, root), kind: repo.kind}
    end
  end

  @doc """
  The tool's gate name: lower-cased, with the editing tools folded into
  `"edit"`.
  """
  @spec tool_name(term()) :: String.t()
  def tool_name(tool) when is_binary(tool) do
    name = String.downcase(tool)
    if name in @edit_tools, do: "edit", else: name
  end

  def tool_name(_tool), do: ""

  # opencode's patch tool names its files in the patch text itself.
  defp patch_paths(text) when is_binary(text) do
    ~r/^\*\*\* (?:Add|Update|Delete) File: (.+)$/m
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [path] -> String.trim(path) end)
  end

  defp patch_paths(_text), do: []

  @doc """
  The directory a shell command acts in: a leading `cd DIR &&` (or `;`),
  then a `git -C DIR` inside what follows, relative to `cwd`.
  """
  @spec subject_dir(String.t() | nil, String.t() | nil) :: String.t() | nil
  def subject_dir(nil, cwd), do: cwd

  def subject_dir(command, cwd) do
    {dir, rest} =
      case Regex.run(~r/\A\s*cd\s+(#{word()})\s*(?:&&|;)(.*)\z/s, command) do
        [_, dir, rest] -> {expand(unquote_word(dir), cwd), rest}
        _ -> {cwd, command}
      end

    case Regex.run(~r/(?:\A|[\s;&|(])git\s+-C\s+(#{word()})/, rest) do
      [_, git_dir] -> expand(unquote_word(git_dir), dir)
      _ -> dir
    end
  end

  defp word, do: ~S/"[^"]*"|'[^']*'|[^\s;&|]+/

  defp unquote_word(<<q, rest::binary>>) when q in [?", ?'], do: String.slice(rest, 0..-2//1)
  defp unquote_word(word), do: word

  defp expand(path, base) do
    path = String.replace(path, ~r/\A(~|\$HOME|\$\{HOME\})(?=\/|\z)/, System.user_home() || "~")

    case base do
      nil -> Path.expand(path)
      base -> Path.expand(path, base)
    end
  end

  @doc """
  The repository containing `dir` (the nearest existing ancestor, for a file
  not yet written) and its kind. A directory outside any repository gives
  `%{root: nil, kind: nil}`.

  The repository's metadata is read from its files, without running `git`:
  the root is the nearest ancestor holding `.git` (a directory, or the file
  a worktree or submodule keeps), and the remotes are the `url`s of the
  `[remote "..."]` sections of its config (the shared one, for a worktree).
  A hook call pays for no process spawn.
  """
  @spec repo_for(String.t() | nil, map()) :: %{root: String.t() | nil, kind: String.t() | nil}
  def repo_for(nil, _config), do: %{root: nil, kind: nil}

  def repo_for(dir, config) do
    with dir when is_binary(dir) <- existing_dir(dir),
         {root, git_dir} <- find_git(dir) do
      %{root: root, kind: kind(remotes(git_dir), config)}
    else
      _ -> %{root: nil, kind: nil}
    end
  end

  defp existing_dir(dir) do
    cond do
      File.dir?(dir) -> dir
      Path.dirname(dir) == dir -> nil
      true -> existing_dir(Path.dirname(dir))
    end
  end

  defp find_git(dir) do
    dot_git = Path.join(dir, ".git")

    cond do
      File.dir?(dot_git) -> {dir, dot_git}
      File.regular?(dot_git) -> linked_git_dir(dir, dot_git)
      Path.dirname(dir) == dir -> nil
      true -> find_git(Path.dirname(dir))
    end
  end

  # A worktree's or submodule's `.git` file names its git directory; a
  # worktree's shares the main repository's config through `commondir`.
  defp linked_git_dir(dir, dot_git) do
    case File.read(dot_git) do
      {:ok, "gitdir: " <> target} ->
        git_dir = Path.expand(String.trim(target), dir)

        case File.read(Path.join(git_dir, "commondir")) do
          {:ok, common} -> {dir, Path.expand(String.trim(common), git_dir)}
          _ -> {dir, git_dir}
        end

      _ ->
        nil
    end
  end

  defp remotes(git_dir) do
    case File.read(Path.join(git_dir, "config")) do
      {:ok, config} -> parse_remotes(config)
      _ -> %{}
    end
  end

  defp parse_remotes(config) do
    config
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce({nil, %{}}, &remote_line/2)
    |> elem(1)
  end

  defp remote_line("[" <> _ = line, {_section, remotes}) do
    case Regex.run(~r/\A\[remote\s+"([^"]+)"\]/, line) do
      [_, name] -> {name, remotes}
      _ -> {nil, remotes}
    end
  end

  defp remote_line(_line, {nil, remotes}), do: {nil, remotes}

  defp remote_line(line, {section, remotes}) do
    case Regex.run(~r/\Aurl\s*=\s*(.+)\z/, line) do
      [_, url] -> {section, Map.put_new(remotes, section, String.trim(url))}
      _ -> {section, remotes}
    end
  end

  defp kind(%{"upstream" => _}, _config), do: "community_fork"

  defp kind(%{"origin" => origin}, config) do
    Enum.find_value(~w(community_fork private first_party), fn kind ->
      if Enum.any?(patterns(config, kind), &Regex.match?(&1, origin)), do: kind
    end)
  end

  defp kind(_remotes, _config), do: nil

  defp patterns(config, kind) do
    config
    |> Map.get(kind, [])
    |> List.wrap()
    |> Enum.flat_map(fn source ->
      case is_binary(source) && Regex.compile(source) do
        {:ok, regex} -> [regex]
        _ -> []
      end
    end)
  end

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_other), do: %{}

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil
end
