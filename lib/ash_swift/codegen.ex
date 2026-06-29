defmodule AshSwift.Codegen do
  @moduledoc """
  Generates Swift source from a domain's reused `typescript_rpc` configuration.

  The generator is intentionally a plain module function: `build_files/1` is
  pure (domains in, `%{relative_path => source}` out) so tests can assert on the
  emitted source without touching the filesystem, and `generate/2` wraps it with
  deterministic, change-only writes.
  """

  alias AshSwift.Codegen.{Emitter, Reader}

  @types_file "AshRpcTypes.swift"
  @functions_file "AshRpcFunctions.swift"

  @doc """
  Builds the generated Swift source for the given domains.

  Returns a map of relative file path to file contents. Pure and deterministic:
  the same domains always produce byte-identical output.

  Raises `Mix.Error` if a generated enum type name collides with a resource
  struct type name (e.g. a resource named `TodoPriority` and a `priority` enum
  field on `Todo` both resolve to `TodoPriority`). The error names the colliding
  type and suggests the fix.
  """
  @spec build_files([module()]) :: %{String.t() => String.t()}
  def build_files(domains) when is_list(domains) do
    %{primary_resources: primary, all_resources: all} = Reader.read(domains)

    %{
      @types_file => Emitter.render_types(all),
      @functions_file => Emitter.render_functions(primary)
    }
  end

  @doc """
  Builds the files for `domains` and writes them under `output_dir`, creating it
  if needed. Writes a file only when its contents changed, so regenerating with
  no schema change produces no diff (and no mtime churn).

  Returns `{:ok, [written_relative_paths]}` where the list is sorted and
  contains only files whose contents actually changed.
  """
  @spec generate([module()], String.t()) :: {:ok, [String.t()]}
  def generate(domains, output_dir) do
    files = build_files(domains)

    written =
      files
      |> Enum.sort_by(fn {path, _} -> path end)
      |> Enum.filter(fn {path, content} ->
        write_if_changed(Path.join(output_dir, path), content)
      end)
      |> Enum.map(fn {path, _} -> path end)

    {:ok, written}
  end

  @doc """
  Returns the sorted list of relative paths whose generated content differs from
  what is currently on disk under `output_dir` (a missing file counts as
  differing). An empty list means the committed output is up to date.

  This is the staleness check behind `mix ash_swift.codegen --check`: CI can fail
  when generated Swift hasn't been regenerated after a schema change (ADR-0005).
  """
  @spec stale_files([module()], String.t()) :: [String.t()]
  def stale_files(domains, output_dir) do
    domains
    |> build_files()
    |> Enum.filter(fn {path, content} ->
      full = Path.join(output_dir, path)
      current = if File.exists?(full), do: File.read!(full), else: :none
      current != content
    end)
    |> Enum.map(fn {path, _} -> path end)
    |> Enum.sort()
  end

  defp write_if_changed(path, content) do
    current = if File.exists?(path), do: File.read!(path), else: :none

    if current == content do
      false
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      true
    end
  end
end
