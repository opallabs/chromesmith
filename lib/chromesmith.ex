defmodule Chromesmith do
  @moduledoc """
  Main module for Chromesmith.
  """
  use GenServer

  defstruct [
    supervisor: nil, # Chromesmith.Supervisor PID
    process_pool_size: 0, # How many Headless Chrome instances to spawn
    page_pool_size: 0, # How many Pages per Instance
    process_pools: [], # List of process pool tuples, {pid, available_pids, all_pids}
    chrome_options: [], # Options to pass into `:chrome_launcher`
  ]

  @type t :: %__MODULE__{
    supervisor: pid(),
    process_pool_size: non_neg_integer(),
    page_pool_size: non_neg_integer(),
    process_pools: [{pid(), [pid()], [pid()]}],
    chrome_options: []
  }

  @doc """
  Check out a Page from one of the headless chrome processes.
  """
  def checkout(pid) do
    GenServer.call(pid, :checkout)
  end

  @doc """
  Check in a Page that has completed work.
  """
  def checkin(pid, worker) do
    GenServer.cast(pid, {:checkin, worker})
  end

  # ---
  # Private
  # ---

  def child_spec(name, opts) do
    %{
      id: name,
      start: {__MODULE__, :start_link, [opts, [name: name]]},
      type: :worker
    }
  end

  def start_link(opts, start_opts \\ []) do
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  def init(opts) when is_list(opts) do
    {:ok, supervisor_pid} = Chromesmith.Supervisor.start_link(opts)

    state = %Chromesmith{
      supervisor: supervisor_pid,
      process_pool_size: Keyword.get(opts, :process_pool_size, 4),
      page_pool_size: Keyword.get(opts, :page_pool_size, 16),
      chrome_options: Keyword.get(opts, :chrome_options, [])
    }

    init(state)
  end

  def init(%Chromesmith{} = state) do
    process_pools = spawn_pools(state.supervisor, state)
    {:ok, %{state | process_pools: process_pools}}
  end

  def spawn_pools(supervisor, state) do
    children =
      Enum.map(1..state.process_pool_size, fn(index) ->
        start_worker(supervisor, index, state)
      end)

    children
  end

  def start_worker(supervisor, index, state) do
    {:ok, child} = Supervisor.start_child(
      supervisor,
      %{
        id: index,
        start: {Chromesmith.Worker, :start_link, [
          {index, state.chrome_options}
        ]},
        restart: :temporary,
        shutdown: 5000,
        type: :worker
      }
    )

    page_pids =
      child
      |> Chromesmith.Worker.start_pages([page_pool_size: state.page_pool_size])

    {child, page_pids, page_pids}
  end

  # ---
  # GenServer Handlers
  # ----

  def handle_call(:checkout, _from, state) do
    {updated_pools, page} =
      state.process_pools
      |> Enum.reduce({[], nil}, fn({pid, available_pages, total_pages} = pool, {pools, found_page}) ->
        if is_nil(found_page) and length(available_pages) > 0 do
          [checked_out_page | new_pages] = available_pages
          new_pool = {pid, new_pages, total_pages}
          {[new_pool | pools], checked_out_page}
        else
          {[pool | pools], found_page}
        end
      end)

    if page do
      {:reply, {:ok, page}, %{state | process_pools: updated_pools}}
    else
      {:reply, :error, state}
    end
  end

  def handle_cast({:checkin, page}, state) do
    updated_pools =
      state.process_pools
      |> Enum.map(fn({pid, available_pages, total_pages} = pool) ->
        # If this page is from this pool, (part of total pages)
        # then return it as an available page only if it hasn't
        # been added before (not already checked into available_pages

        if Enum.find(total_pages, &(&1 == page)) && !Enum.find(available_pages, &(&1 == page)) do
          {pid, [page | available_pages], total_pages}
        else
          pool
        end
      end)

    {:noreply, %{state | process_pools: updated_pools}}
  end
end
