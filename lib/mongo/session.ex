defmodule Mongo.Session do

  @moduledoc """
  This module implements the details of the transactions api ([see specs](https://github.com/mongodb/specifications/blob/master/source/transactions/transactions.rst#committransaction)).

  In case of MongoDB 3.6 or greater the driver uses sessions for each operation. If no session is created the driver will create a so-called implicit session. A session is a UUID-Number which
  is added to some operations. The sessions are used to manage the transaction state as well. In most situation you need not to create a session instance, so the api of the driver is not changed.

  In case of multiple insert statemantes you can use transaction (MongoDB 4.x) to be sure that all operations are grouped like a single operation. Prerequisites for transactions are:
  MongoDB 4.x must be used as replica set or cluster deployment. The collection used in the operations must already exist. Some operation are not allowed (For example: create index or call count).

  ## Example

      alias Mongo.Session

      {:ok, session} = Session.start_session(top, :write, [])
      :ok = Session.start_transaction(session)

      Mongo.insert_one(top, "dogs", %{name: "Greta"}, session: session)
      Mongo.insert_one(top, "dogs", %{name: "Waldo"}, session: session)
      Mongo.insert_one(top, "dogs", %{name: "Tom"}, session: session)

      :ok = Session.commit_transaction(session)
      :ok = Session.end_session(top, session)

  First you start a explicit session and a transactions. Use the session for each insert statement as an options with key `:session` otherwise the insert statement won't be
  executed in the transaction. After that you commit the transaction and end the session by calling `end_session`.

  ## Convenient API for Transactions

  This method is responsible for starting a transaction, invoking a callback, and committing a transaction.
  The callback is expected to execute one or more operations with the transaction; however, that is not enforced.
  The callback is allowed to execute other operations not associated with the transaction.

  ## Example

      {:ok, ids} = Session.with_transaction(top, fn opts ->
        {:ok, %InsertOneResult{:inserted_id => id1}} = Mongo.insert_one(top, "dogs", %{name: "Greta"}, opts)
        {:ok, %InsertOneResult{:inserted_id => id2}} = Mongo.insert_one(top, "dogs", %{name: "Waldo"}, opts)
        {:ok, %InsertOneResult{:inserted_id => id3}} = Mongo.insert_one(top, "dogs", %{name: "Tom"}, opts)
        {:ok, [id1, id2, id3]}
      end, w: 1)

  If the callback is successfull then it returns a tupel with the keyword `:ok` and a used defined result like `{:ok, [id1, id2, id3]}`. In this example we use
  the write concern `w: 1`. The write concern used in the insert operation will be removed by the driver. It is applied in the commit transaction command.

  ## Implicit vs explicit sessions

  In most cases the driver will create implicit sessions for you. Each time when you run a query or a command the driver
  executes the following functions:

      with {:ok, session} <- Session.start_implicit_session(topology_pid, type, opts),
         result <- exec_command_session(session, new_cmd, opts),
         :ok <- Session.end_implict_session(topology_pid, session) do
      ...

  This behaviour is specified by the mongodb specification for [drivers](https://github.com/mongodb/specifications/blob/master/source/sessions/driver-sessions.rst#explicit-vs-implicit-sessions).

  If you use the `:causal_consistency` flag, then you need to create an explicit session:

      alias Mongo.Session

      {:ok, session} = Session.start_session(top, :write, causal_consistency: true)

      Mongo.delete_many(top, "dogs", %{"Greta"}, session: session)
      {:ok, 0} = Mongo.count(top, "dogs", %{name: "Greta"}, session: session)

      :ok = Session.end_session(top, session)

  For more information about causal consistency see the [officially documentation](https://docs.mongodb.com/manual/core/read-isolation-consistency-recency/#causal-consistency).

  If you want to use transaction, then you need to create a session as well:

      alias Mongo.Session

      {:ok, session} = Session.start_session(top, :write, [])
      :ok = Session.start_transaction(session)

      Mongo.insert_one(top, "dogs", %{name: "Greta"}, session: session)
      Mongo.insert_one(top, "dogs", %{name: "Waldo"}, session: session)
      Mongo.insert_one(top, "dogs", %{name: "Tom"}, session: session)

      :ok = Session.commit_transaction(session)
      :ok = Session.end_session(top, session)

  You can shorten this code by using the `with_transaction` function:

      alias Mongo.Session

      {:ok, ids} = Session.with_transaction(top, fn opts ->
        {:ok, %InsertOneResult{:inserted_id => id1}} = Mongo.insert_one(top, "dogs", %{name: "Greta"}, opts)
        {:ok, %InsertOneResult{:inserted_id => id2}} = Mongo.insert_one(top, "dogs", %{name: "Waldo"}, opts)
        {:ok, %InsertOneResult{:inserted_id => id3}} = Mongo.insert_one(top, "dogs", %{name: "Tom"}, opts)
        {:ok, [id1, id2, id3]}
      end, w: 1)

  """

  import Keywords
  import Mongo.WriteConcern

  alias Mongo.Session.ServerSession
  alias Mongo.Session
  alias Mongo.Topology
  alias BSON.Timestamp

  require Logger

  @type t :: pid()

  ##
  # The data:
  # * `conn` the used connection to the database
  # * `server_session` the server_session data
  # * `opts` options
  # * `implicit` true or false
  # * `causal_consistency` true orfalse
  # * `wire_version` current wire version to check if transactions are possible
  # * `recovery_token` tracked recovery token from response in a sharded transaction
  defstruct [conn: nil, recovery_token: nil, server_session: nil, causal_consistency: false, operation_time: nil, implicit: false, wire_version: 0, state: :no_transaction, opts: []]

  @doc """
  Start the generic state machine.
  """
  @spec start_link(GenServer.server, ServerSession.t, atom, integer, keyword()) :: {:ok, Session.t} | :ignore | {:error, term()}
  def start_link(conn, server_session, type, wire_version, opts) do
    {:ok, spawn_link(__MODULE__, :init, [conn, server_session, type, wire_version, opts])}
  end

  @doc """
  Start a new session for the `topology_pid`. You need to specify the `type`: `:read` for read and `:write` for write
  operations.

  ## Example
      {:ok, session} = Session.start_session(top, :write, [])

  """
  @spec start_session(GenServer.server, atom, keyword()) :: {:ok, Session.t} | {:error, term()}
  def start_session(topology_pid, type, opts \\ []) do
    with {:ok, session} <- Topology.checkout_session(topology_pid, type, :explicit, opts) do
      {:ok, session}
    else
      {:new_connection, _server} ->
        :timer.sleep(1000)
        start_session(topology_pid, type, opts)
    end
  end

  @doc """
  Start a new implicit session only if no explicit session exists. It returns the session in the `opts` keyword list or
  creates a new one.
  """
  @spec start_implicit_session(GenServer.server, atom, keyword()) :: {:ok, Session.t} | {:error, term()}
  def start_implicit_session(topology_pid, type, opts) do
    case Keyword.get(opts, :session, nil) do
      nil ->
        with {:ok, session} <- Topology.checkout_session(topology_pid, type, :implicit, opts) do
          {:ok, session}
        else
          {:new_connection, _server} ->
            :timer.sleep(1000)
            start_implicit_session(topology_pid, type, opts)
        end
      session -> {:ok, session}
    end
  end

  @doc """
  Start a new transation.
  """
  @spec start_transaction(Session.t) :: :ok | {:error, term()}
  def start_transaction(pid) do
    call(pid, :start_transaction)
  end

  @doc """
  Commit the current transation.
  """
  @spec commit_transaction(Session.t) :: :ok | {:error, term()}
  def commit_transaction(pid) do
    call(pid, :commit_transaction)
  end

  @doc """
  Abort the current transation and rollback all changes.
  """
  @spec abort_transaction(Session.t) :: :ok | {:error, term()}
  def abort_transaction(pid) do
    call(pid, :abort_transaction)
  end

  @doc """
  Merge the session / transaction data into the cmd. There is no need to call this function directly. It is called automatically.
  """
  @spec bind_session(Session.t, BSON.document) :: :ok | {:error, term()}
  def bind_session(nil, cmd) do
    cmd
  end
  def bind_session(pid, cmd) do
    call(pid, {:bind_session, cmd})
  end

  @doc """
  Update the `operationTime` for causally consistent read commands. There is no need to call this function directly. It is called automatically.
  """
  @spec update_session(Session.t, %{key: BSON.Timestamp.t}, keyword()) :: BSON.document
  def update_session(pid, doc, opts \\ [])
  def update_session(pid, doc, opts) do
    case opts |> write_concern() |> acknowledged?() do
      true  -> advance_operation_time(pid, doc["operationTime"])
      false -> []
    end
    update_recovery_token(pid, doc["recoveryToken"])
    doc
  end

  @doc """
  Advance the `operationTime` for causally consistent read commands
  """
  @spec advance_operation_time(Session.t, BSON.Timestamp.t) :: none()
  def advance_operation_time(_pid, nil) do
  end
  def advance_operation_time(pid, timestamp) do
    cast(pid, {:advance_operation_time, timestamp})
  end

  @doc """
  Update the `recoveryToken` after each response from mongos
  """
  @spec update_recovery_token(Session.t, BSON.document) :: none()
  def update_recovery_token(_pid, nil) do
  end
  def update_recovery_token(pid, recovery_token) do
    cast(pid, {:update_recovery_token, recovery_token})
  end

  @doc """
  End implicit session. There is no need to call this function directly. It is called automatically.
  """
  @spec end_implict_session(GenServer.server, Session.t) :: :ok | :error
  def end_implict_session(topology_pid, session) do
    with {:ok, session_server} <- call(session, :end_implicit_session) do
      Topology.checkin_session(topology_pid, session_server)
    else
      :noop -> :ok
      _     -> :error
    end
  end

  @doc """
  End explicit session.
  """
  @spec end_session(GenServer.server, Session.t) :: :ok | :error
  def end_session(topology_pid, session) do
    with {:ok, session_server} <- call(session, :end_session) do
      Topology.checkin_session(topology_pid, session_server)
    end
  end

  @doc """
  Convenient function for running multiple write commands in a transaction.

  ## Example
      alias Mongo.Session

      {:ok, ids} = Session.with_transaction(top, fn opts ->
      {:ok, %InsertOneResult{:inserted_id => id1}} = Mongo.insert_one(top, "dogs", %{name: "Greta"}, opts)
      {:ok, %InsertOneResult{:inserted_id => id2}} = Mongo.insert_one(top, "dogs", %{name: "Waldo"}, opts)
      {:ok, %InsertOneResult{:inserted_id => id3}} = Mongo.insert_one(top, "dogs", %{name: "Tom"}, opts)
      {:ok, [id1, id2, id3]}
      end, w: 1)

  """
  @spec with_transaction(Session.t, (keyword() -> {:ok, any()} | :error)) :: {:ok, any()} | :error | {:error, term}
  def with_transaction(topology_pid, fun, opts \\ []) do

    with {:ok, session} <- Session.start_session(topology_pid, :write, opts),
         :ok            <- Session.start_transaction(session) do

      with {:ok, result} <- run_function(fun, Keyword.merge(opts, session: session)) do
        commit_transaction(session)
        end_session(topology_pid, session)
        {:ok, result}
      else
        error ->
          abort_transaction(session)
          end_session(topology_pid, session)
          error
      end

    end

  end

  ##
  # calling the function and wrapping it to catch exceptions
  #
  defp run_function(fun, opts) do

    ## todo wait max 120s
    try do
      fun.(opts)
    rescue
      reason -> {:error, reason}
    end

  end

  @doc """
  Return the connection used in the session.
  """
  @spec connection(Session.t) :: pid
  def connection(pid) do
    call(pid, :connection)
  end

  @doc """
  Return the server session used in the session.
  """
  @spec server_session(Session.t) :: ServerSession.t
  def server_session(pid) do
    call(pid, :server_session)
  end

  @doc"""
  Check if the session is alive.
  """
  @spec server_session(Session.t) :: boolean()
  def alive?(nil), do: false
  def alive?(pid), do: Process.alive?(pid)

  @compile {:inline, call: 2}
  defp call(pid, arguments) do
    #Logger.info("Calling #{inspect arguments}")
    send(pid, {:call, self(), arguments})
    receive do
      {:session_result, result} -> result
    end
  end

  @compile {:inline, cast: 2}
  def cast(pid, arguments) do
    send(pid, {:cast, arguments})
  end

  def init(conn, server_session, type, wire_version, opts) do
    data = %Session{conn: conn,
      server_session: server_session,
      implicit: (type == :implicit),
      wire_version: wire_version,
      recovery_token: nil,
      causal_consistency: Keyword.get(opts, :causal_consistency, false),
      state: :no_transaction,
      opts: opts}
    loop(data)
  end

  defp loop(nil) do
  end
  defp loop(%Session{state: state} = data) do
    receive do
      {:call, from, cmd} ->

        handle_call_event(cmd, state, data)
        |> handle_call_result(data, from)
        |> loop()

      {:cast, cmd} -> loop(handle_cast_event(cmd, state, data))

      _other -> loop(nil)

    end
  end

  defp handle_call_result({:keep_state_and_data, result}, data, from) do
    send(from, {:session_result, result})
    data
  end
  defp handle_call_result({:next_state, new_state, result}, data, from) do
    send(from, {:session_result, result})
    %Session{data | state: new_state}
  end
  defp handle_call_result({:next_state, new_state, data, result}, _old_data, from) do
    send(from, {:session_result, result})
    %Session{data | state: new_state}
  end
  defp handle_call_result({:stop_and_reply, result}, _data, from) do
    send(from, {:session_result, result})
    nil
  end

  def handle_call_event(:start_transaction, transaction, %Session{server_session: session} = data) when transaction in [:no_transaction, :transaction_aborted, :transaction_committed] do
    {:next_state, :starting_transaction, %Session{data | recovery_token: nil, server_session: ServerSession.next_txn_num(session)}, :ok}
  end
  ##
  # bind session: only if wire_version >= 6, MongoDB 3.6.x and no transaction is running: only lsid is added
  #
  def handle_call_event({:bind_session, cmd}, transaction,
        %Session{conn: conn,
          wire_version: wire_version,
          server_session: %ServerSession{session_id: id}} = data) when wire_version >= 6 and transaction in [:no_transaction, :transaction_aborted, :transaction_committed] do

    cmd = Keyword.merge(cmd, lsid: %{id: id}, readConcern: read_concern(data, Keyword.get(cmd, :readConcern))) |> filter_nils()
    {:keep_state_and_data, {:ok, conn, cmd}}
  end
  def handle_call_event({:bind_session, cmd}, :starting_transaction,
        %Session{conn: conn,
          server_session: %ServerSession{session_id: id, txn_num: txn_num},
          wire_version: wire_version} = data) when wire_version >= 6 do

    result = Keyword.merge(cmd,
               readConcern: read_concern(data, Keyword.get(cmd, :readConcern)),
               lsid: %{id: id},
               txnNumber: %BSON.LongNumber{value: txn_num},
               startTransaction: true,
               autocommit: false) |> filter_nils() |> Keyword.drop(~w(writeConcern)a)

    {:next_state, :transaction_in_progress, {:ok, conn, result}}
  end
  def handle_call_event({:bind_session, cmd}, :transaction_in_progress,
        %Session{conn: conn, wire_version: wire_version,
          server_session: %ServerSession{session_id: id, txn_num: txn_num}}) when wire_version >= 6 do
    result = Keyword.merge(cmd,
               lsid: %{id: id},
               txnNumber: %BSON.LongNumber{value: txn_num},
               autocommit: false) |> Keyword.drop(~w(writeConcern readConcern)a)
    {:keep_state_and_data, {:ok, conn, result}}
  end
  # In case of wire_version < 6 we do nothing
  def handle_call_event({:bind_session, cmd}, _transaction,  %Session{conn: conn}) do
    {:keep_state_and_data, {:ok, conn, cmd}}
  end
  def handle_call_event(:commit_transaction, :starting_transaction, _data) do
    {:next_state, :transaction_committed, :ok}
  end
  def handle_call_event(:commit_transaction, :transaction_in_progress, data) do
    {:next_state, :transaction_committed, run_commit_command(data)}
  end
  def handle_call_event(:abort_transaction, :starting_transaction, _data) do
    {:next_state, :transaction_aborted, :ok}
  end
  def handle_call_event(:abort_transaction, :transaction_in_progress, data) do
    {:next_state, :transaction_aborted, run_abort_command(data)}
  end
  def handle_call_event(:connection, _state,  %{conn: conn}) do
    {:keep_state_and_data, conn}
  end
  def handle_call_event(:end_session, _state, %Session{server_session: session_server}) do
    {:stop_and_reply, {:ok, session_server}}
  end
  def handle_call_event(:end_implicit_session, _state, %Session{server_session: session_server, implicit: true}) do
    {:stop_and_reply, {:ok, session_server}}
  end
  def handle_call_event(:end_implicit_session, _state, %Session{implicit: false}) do
    {:keep_state_and_data, :noop}
  end
  def handle_call_event(:server_session, _state,  %Session{server_session: session_server, implicit: implicit}) do
    {:keep_state_and_data, session_server, implicit}
  end
  def handle_cast_event({:update_recovery_token, recovery_token}, _state, %Session{} = data) do
    %Session{data | recovery_token: recovery_token}
  end
  def handle_cast_event({:advance_operation_time, timestamp}, _state, %Session{operation_time: nil} = data) do
    %Session{data | operation_time: timestamp}
  end
  def handle_cast_event({:advance_operation_time, timestamp}, _state, %Session{operation_time: time} = data)  do
    case Timestamp.is_after(timestamp, time) do
      true  -> %Session{data | operation_time: timestamp}
      false -> data
    end
  end
  ##
  # Run the commit transaction command.
  #
  defp run_commit_command(%Session{conn: conn, recovery_token: recovery_token, server_session: %ServerSession{session_id: id, txn_num: txn_num}, opts: opts}) do

    Logger.debug("Running commit transaction")

    cmd = [
            commitTransaction: 1,
            lsid: %{id: id},
            txnNumber: %BSON.LongNumber{value: txn_num},
            autocommit: false,
            writeConcern: write_concern(opts),
            maxTimeMS: max_time_ms(opts),
           recoveryToken: recovery_token
          ] |> filter_nils()

    _doc = Mongo.exec_command(conn, cmd, database: "admin")

    :ok
  end

  defp max_time_ms(opts) do
    opts |> Keyword.get(:max_commit_time_ms) |> optional_int64()
  end
  defp optional_int64(nil), do: nil
  defp optional_int64(value), do: %BSON.LongNumber{value: value}

  ##
  # Run the abort transaction command.
  #
  defp run_abort_command(%Session{conn: conn, server_session: %ServerSession{session_id: id, txn_num: txn_num}, opts: opts}) do

    Logger.debug("Running abort transaction")

    cmd = [
            abortTransaction: 1,
            lsid: %{id: id},
            txnNumber: %BSON.LongNumber{value: txn_num},
            autocommit: false,
            writeConcern: write_concern(opts)
          ] |> filter_nils()

    _doc = Mongo.exec_command(conn, cmd, database: "admin")

    :ok
  end

  ##
  # create the readConcern options
  #
  defp read_concern(%Session{causal_consistency: false}, read_concern) do
    read_concern
  end
  defp read_concern(%Session{causal_consistency: true, operation_time: nil}, read_concern) do
    read_concern
  end
  defp read_concern(%Session{causal_consistency: true, operation_time: time}, nil) do
    [afterClusterTime: time]
  end
  defp read_concern(%Session{causal_consistency: true, operation_time: time}, read_concern) when is_map(read_concern) do
    Map.put(read_concern, :afterClusterTime, time)
  end
  defp read_concern(%Session{causal_consistency: true, operation_time: time}, read_concern) when is_list(read_concern) do
    read_concern ++ [afterClusterTime: time]
  end

end