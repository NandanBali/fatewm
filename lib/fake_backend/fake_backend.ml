(* M0 minimal driver — expanded in M2 by the Fake Backend agent. *)

open Mlwm_proto

type trace = {
  init_commands : Command.t list;
  steps : (Event.t * Command.t list) list;
}

let run_script ~outputs ~windows ~events ~init ~on_event =
  let state0, init_commands = init ~outputs ~windows in
  let final_state, rev_steps =
    List.fold_left
      (fun (st, acc) ev ->
        let st', cmds = on_event st ev in
        (st', (ev, cmds) :: acc))
      (state0, []) events
  in
  (final_state, { init_commands; steps = List.rev rev_steps })
