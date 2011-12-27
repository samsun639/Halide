open Llvm
open Ir
open Util

exception UnsupportedType of val_type
exception CGFailed of string
exception BCWriteFailed of string

let raw_buffer_t c = pointer_type (i8_type c)

let verify_cg m =
    (* verify the generated module *)
    match Llvm_analysis.verify_module m with
      | Some reason -> raise(CGFailed(reason))
      | None -> ()

let type_of_val_type c t = match t with
  | UInt(1) | Int(1) -> i1_type c
  | UInt(8) | Int(8) -> i8_type c
  | UInt(16) | Int(16) -> i16_type c
  | UInt(32) | Int(32) -> i32_type c
  | UInt(64) | Int(64) -> i64_type c
  | Float(32) -> float_type c
  | Float(64) -> double_type c
  | IntVector( 1, n) | UIntVector( 1, n) -> vector_type (i1_type c) n
  | IntVector( 8, n) | UIntVector( 8, n) -> vector_type (i8_type c) n
  | IntVector(16, n) | UIntVector(16, n) -> vector_type (i16_type c) n
  | IntVector(32, n) | UIntVector(32, n) -> vector_type (i32_type c) n
  | IntVector(64, n) | UIntVector(64, n) -> vector_type (i64_type c) n
  | FloatVector(32, n) -> vector_type (float_type c) n
  | FloatVector(64, n) -> vector_type (double_type c) n
  | _ -> raise (UnsupportedType(t))


(* get references to the support functions *)
let get f name = match f name with
  | Some v -> v
  | None -> raise (Wtf ("Couldn't find " ^ name ^ " in module"))

let get_function m = get (fun nm -> lookup_function nm m)

let get_type m = get (type_by_name m)

let buffer_t m =
  get_type m "struct.buffer_t"

(*
 * Build wrapper
 *)
let cg_wrapper c m e inner =
  (* unpack entrypoint *)
  let (entrypoint_name, arglist, _) = e in

  (* rename the inner function *)
  ignore (set_value_name (entrypoint_name ^ "_inner") inner);

  let buffer_struct_type = buffer_t m in

  let type_of_arg = function
    | Scalar (_, vt) -> type_of_val_type c vt
    | Buffer _ -> pointer_type (buffer_struct_type)
  in

  let f = define_function
            entrypoint_name
            (function_type
               (void_type c)
               (Array.of_list (List.map type_of_arg arglist)))
            m in
  let b = builder_at_end c (entry_block f) in
  
  let args = Array.of_list
               (List.combine
                  arglist
                  (Array.to_list (params f))) in

  Printf.printf "Building wrapper\n%!";
  Printf.printf "  %d args\n" (List.length arglist);
  Printf.printf "  %d params\n%!" (Array.length (params f));
  Printf.printf "  %d inner params\n%!" (Array.length (params inner));

  ignore (
    build_call
      inner
      (Array.map
         begin function
           | Buffer nm, param ->
               build_load (build_struct_gep param 0 (nm ^ ".host") b) "" b
           | _, param -> param
         end
         args
      )
      ""
      b
  );
  ignore (build_ret_void b);

  Printf.printf "Built wrapper\n%!";
  dump_value f;

  f
