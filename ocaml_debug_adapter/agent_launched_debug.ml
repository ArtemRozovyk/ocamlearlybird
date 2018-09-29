open Debug_adapter_protocol
open Debug_protocol
open Debug_protocol_ex
open Signatures

module Make (Args : sig
    val rpc : Rpc.t
    val replace_agent : (module AGENT) -> unit
    val init_args : Initialize_command.Request.Arguments.t
    val caps : Capabilities.t
    val launch_args : Launch_command.Request.Arguments.t
    val proc : Agent_launched.launched_process
    val symbols : Symbols.t
    val conn : Debug_conn.t
    val pid : int
  end) = struct

  include Agent_null
  include Args
  include Agent_launched.Make (Args)

  let trans_pos kind (line, column) =
    let to_client_line_adjust = if init_args.lines_start_at1 then 0 else -1 in
    let to_client_column_adjust = if init_args.columns_start_at1 then 0 else -1 in
    match kind with
    | `Adapter_to_client ->
      (line + to_client_line_adjust, column + to_client_column_adjust)
    | `Client_to_adapter ->
      (line - to_client_line_adjust, column - to_client_column_adjust)

  let source_by_modname =
    let tbl = Hashtbl.create 0 in
    List.iter (fun (mi : Symbols.debug_module_info) ->
      if BatOption.is_some mi.source then (
        Hashtbl.add tbl mi.name Source.({
          name = Some mi.name;
          path = mi.source;
          source_reference = None;
          presentation_hint = None;
          origin = None; (* TODO *)
          sources = [];
          adapter_data = `Assoc [];
          checksums = [];
        })
      )
    ) (Symbols.module_infos symbols);
    tbl

  let shutdown () =
    Lwt.pick [
      Debug_conn.stop conn;
      (
        Lwt_unix.sleep 1.0;%lwt
        let () = match proc with
          | In_terminal -> ()
          | Process proc -> proc#terminate
        in
        Lwt.return_unit
      )
    ];%lwt
    Rpc.emit_event rpc (module Terminated_event) { restart = `Assoc [] };%lwt
    replace_agent (module Agent_disconnected);
    Lwt.return_unit

  module Breakpoints = Breakpoints.Make (struct
      include Args
      let trans_pos = trans_pos
      let source_by_modname = source_by_modname
    end)
  module Inspect = Inspect.Make (struct
      include Args
      let trans_pos = trans_pos
      let source_by_modname = source_by_modname
      let shutdown = shutdown
    end)
  module Time_travel = Time_travel.Make (struct
      include Args
      let report = Inspect.report
      let has_breakpoint_at = Breakpoints.has_breakpoint_at
      let get_frames = Inspect.get_frames
    end)

  let disconnect_command _ =
    print_endline "disconnect";
    shutdown ();%lwt
    print_endline "disconnect ok";
    Lwt.return_ok ()

  let set_breakpoints_command = Breakpoints.set_breakpoints_command
  let set_exception_breakpoints_command = Breakpoints.set_exception_breakpoints_command
  let set_function_breakpoints_command = Breakpoints.set_function_breakpoints_command

  let loaded_sources_command = Inspect.loaded_sources_command
  let source_command = Inspect.source_command
  let threads_command = Inspect.threads_command
  let stack_trace_command = Inspect.stack_trace_command
  let scopes_command = Inspect.scopes_command
  let variables_command = Inspect.variables_command
  let evaluate_command = Inspect.evaluate_command
  let completions_command = Inspect.completions_command
  let set_variable_command = Inspect.set_variable_command
  let set_expression_command = Inspect.set_expression_command

  let configuration_done_command = Time_travel.configuration_done_command
  let pause_command = Time_travel.pause_command
  let next_command = Time_travel.next_command
  let continue_command = Time_travel.continue_command
  let step_in_command = Time_travel.step_in_command
  let step_in_targets_command = Time_travel.step_in_targets_command
  let step_out_command = Time_travel.step_out_command
  let step_back_command = Time_travel.step_back_command
  let reverse_continue_command = Time_travel.reverse_continue_command
end
