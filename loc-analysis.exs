#! /usr/bin/env elixir

Mix.install([
  {:csv, "~> 3.0"}
])

defmodule GitCommandError do
  defexception message: "Git command failed."

  @impl true
  def exception(value) do
    case value do
      [] -> %GitCommandError{}
      _ -> %GitCommandError{message: "Git command failed: " <> value}
    end
  end
end

defmodule Git do
  def get_snapshot!(commit_hash) do
    with destination_path <- System.tmp_dir!(),
         {:ok, tar_file} <- call_git_archive!(commit_hash, destination_path),
         :ok <- call_tar_extract!(tar_file, destination_path),
         :ok <- Path.join(destination_path, tar_file) |> File.rm!() do
      {:ok, Path.join(destination_path, commit_hash)}
    end
  end

  def monthly_commits do
    call_git_log!()
    |> String.split("\n")
    |> Stream.uniq_by(&year_month_of/1)
  end

  def weekly_commits do
    call_git_log!()
    |> String.split("\n")
    |> Stream.uniq_by(&beginning_of_week/1)
  end

  def call_git_log! do
    case System.cmd("git", [
           "log",
           "--pretty=format:%ad,%H",
           "--date=iso",
           "--date=short",
           "--reverse"
         ]) do
      {log, 0} -> log
      {error_msg, _} -> raise GitCommandError, error_msg
    end
  end

  def parse_git_log_line(log_line), do: log_line |> String.split(",")

  defp year_month_of(commit), do: commit |> String.slice(0..6)

  defp beginning_of_week(commit),
    do:
      commit
      |> String.slice(0..9)
      |> Date.from_iso8601()
      |> elem(1)
      |> Date.beginning_of_week()
      |> Date.to_string()

  defp call_git_archive!(commit_hash, temp_dir_path_str) do
    System.cmd("git", [
      "archive",
      commit_hash,
      "--prefix=#{commit_hash}/",
      "--format=tar",
      "--output=#{temp_dir_path_str}/#{commit_hash}.tar"
    ])
    |> case do
      {_, 0} -> {:ok, "#{commit_hash}.tar"}
    end
  end

  defp call_tar_extract!(archive_file, archive_location) do
    System.cmd(
      "tar",
      [
        "xf",
        archive_file
      ],
      cd: archive_location
    )
    |> case do
      {_, 0} -> :ok
    end
  end
end

defmodule Analysis do
  def monthly(file) do
    Git.monthly_commits()
    |> Task.async_stream(&run_loc_analysis!/1, on_timeout: :kill_task, timeout: 30_000)
    |> Stream.reject(fn task_result -> {:exit, _} |> match?(task_result) end)
    |> Stream.map(fn {:ok, analysis} -> analysis end)
    |> Enum.to_list()
    |> Enum.map_reduce(
      %MapSet{},
      fn analysis, headers ->
        {
          analysis,
          analysis |> Map.keys() |> MapSet.new() |> MapSet.union(headers)
        }
      end
    )
    |> then(fn {analysis_arr, headers} ->
      analysis_arr |> CSV.encode(headers: Enum.to_list(headers))
    end)
    |> Stream.each(&IO.write(file, &1))
    |> Enum.to_list()
  end

  def weekly(file) do
    Git.weekly_commits()
    |> Task.async_stream(&run_loc_analysis!/1, on_timeout: :kill_task, timeout: 30_000)
    |> Stream.reject(fn task_result -> {:exit, _} |> match?(task_result) end)
    |> Stream.map(fn {:ok, analysis} -> analysis end)
    |> Enum.to_list()
    |> Enum.map_reduce(
      %MapSet{},
      fn analysis, headers ->
        {
          analysis,
          analysis |> Map.keys() |> MapSet.new() |> MapSet.union(headers)
        }
      end
    )
    |> then(fn {analysis_arr, headers} ->
      analysis_arr |> CSV.encode(headers: Enum.to_list(headers))
    end)
    |> Stream.each(&IO.write(file, &1))
    |> Enum.to_list()
  end

  defp run_loc_analysis!(commit) do
    [date, commit_hash] = Git.parse_git_log_line(commit)
    {:ok, snapshot_dir} = Git.get_snapshot!(commit_hash)

    run_loc!(date, snapshot_dir)
  end

  defp run_loc!(date, snapshot_dir) do
    {:ok, tokei_result} = call_tokei!(snapshot_dir)
    parsed_tokei_result = parse_tokei(tokei_result)
    merged_result = parsed_tokei_result |> Map.put("Date", date)

    merged_result
  end

  defp call_tokei!(snapshot_dir) do
    System.cmd(
      "tokei",
      [
        ".",
        "--compact"
      ],
      cd: snapshot_dir
    )
    |> case do
      {tokei_result, 0} -> {:ok, tokei_result}
    end
  end

  defp parse_tokei(tokei_result) do
    tokei_result
    |> String.split("\n")
    |> Enum.map(&parse_tokei_item/1)
    |> Enum.filter(fn x -> x != :invalid_item end)
    |> Enum.reduce(%{}, fn {language, loc}, accum ->
      accum |> Map.put(language, loc)
    end)
  end

  defp parse_tokei_item(item) do
    item
    |> String.trim()
    |> String.split(~r/[\s]{2,}/, trim: true)
    |> case do
      ["Language" | _] -> :invalid_item
      ["Total" | _] -> :invalid_item
      [language, _, _, loc | _] -> {language, loc}
      _ -> :invalid_item
    end
  end
end

defmodule CLI do
  def run(args) do
    case args do
      ["monthly"] -> File.open!("monthly.csv", [:write, :utf8]) |> Analysis.monthly()
      ["weekly"] -> File.open!("weekly.csv", [:write, :utf8]) |> Analysis.weekly()
      _ -> Process.exit(self(), "Invalid command. Usage: FIXME")
    end
  end
end

CLI.run(System.argv())
