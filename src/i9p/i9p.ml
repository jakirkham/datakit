open Rresult
open Lwt.Infix
open Vfs.Error.Infix

module PathSet = I9p_merge.PathSet

module type S = sig
  type repo
  val create: string Irmin.Task.f -> repo -> Vfs.Dir.t
end

let ok = Vfs.ok
let err_enoent = Lwt.return Vfs.Error.noent
let err_eisdir = Lwt.return Vfs.Error.isdir
let err_read_only = Lwt.return Vfs.Error.read_only_file
let err_already_exists name = Vfs.error "Entry %S already exists" name
let err_conflict msg = Vfs.error "Merge conflict: %s" msg
let err_unknown_cmd x = Vfs.error "Unknown command %S" x
let err_invalid_commit_id id = Vfs.error "Invalid commit ID %S" id
let err_invalid_hash h x =
  Vfs.error "invalid-hash %S: %s" h (Printexc.to_string x)
let err_not_fast_forward = Vfs.error "not-fast-forward"

module StringMap = Map.Make(String)

module Make (Store : I9p_tree.STORE) = struct

  type repo = Store.Repo.t
  let empty_inode_map: Vfs.Inode.t StringMap.t = StringMap.empty

  module Path = Irmin.Path.String_list
  module Tree = I9p_tree.Make(Store)
  module View = Irmin.View(Store)
  module Merge = I9p_merge.Make(Store)(View)
  module Remote = I9p_remote.Make(Store)

  let irmin_ro_file ~get_root path =
    let read () =
      get_root () >>= fun root ->
      Tree.node root path >>= function
      | `None         -> Lwt.return (Ok None)
      | `Directory _  -> err_eisdir
      | `File content ->
        let contents_t = Store.Private.Repo.contents_t (Tree.repo root) in
        Store.Private.Contents.read_exn contents_t content >|= fun content ->
        Ok (Some (Cstruct.of_string content))
    in
    Vfs.File.of_kvro ~read

  let irmin_rw_file ~remove_conflict ~view path =
    let read () =
      View.read view path >|= function
      | None         -> Ok None
      | Some content -> Ok (Some (Cstruct.of_string content))
    in
    let write data =
      View.update view path (Cstruct.to_string data) >|= fun () ->
      remove_conflict path;
      Ok ()
    in
    let remove () =
      View.remove view path >|= fun () ->
      remove_conflict path; Ok ()
    in
    Vfs.File.of_kv ~read ~write ~remove

  let name_of_irmin_path ~root path =
    match Path.rdecons path with
    | None -> root
    | Some (_, leaf) -> leaf

  let ro_tree ~name ~get_root =
    let name_of_irmin_path = name_of_irmin_path ~root:name in
    (* Keep track of which qids we're still using. We need to give the
       same qid to the client each time. TODO: use a weak map here. *)
    let nodes = Hashtbl.create 10 in

    let rec get ~dir (ty, leaf) =
      let hash_key = (ty, Path.rcons dir leaf) in
      try Hashtbl.find nodes hash_key
      with Not_found ->
        let inode = inode_of hash_key in
        Hashtbl.add nodes hash_key inode;
        inode

    and inode_of (ty, full_path) =
      match ty with
      | `Directory -> irmin_ro_dir full_path
      | `File      ->
        let path = name_of_irmin_path full_path in
        let file = irmin_ro_file ~get_root full_path in
        Vfs.Inode.file path file

    and irmin_ro_dir path =
      let name = name_of_irmin_path path in
      let ls () =
        get_root () >>= fun root ->
        Tree.get_dir root path >>= function
        | None -> err_enoent
        | Some dir ->
          Tree.ls dir >>= fun items ->
          ok (List.map (get ~dir:path) items)
      in
      let lookup name =
        get_root () >>= fun root ->
        Tree.get_dir root path >>= function
        | None -> err_enoent
        | Some dir ->
          Tree.ty dir name >>= function
          | `File
          | `Directory as ty -> ok (get ~dir:path (ty, name))
          | `None            -> err_enoent
      in
      let remove () = Vfs.Dir.err_read_only in
      Vfs.Dir.read_only ~ls ~lookup ~remove |> Vfs.Inode.dir name
    in
    irmin_ro_dir []

  let read_only store = ro_tree ~get_root:(fun () -> Tree.snapshot store)

  (* Ugly! *)
  let snapshot ~store view =
    let task () = Irmin.Task.empty in
    let repo = Store.repo (store "snapshot") in
    Store.empty task repo >>= fun dummy_store ->
    let dummy_store = dummy_store () in
    View.make_head dummy_store Irmin.Task.empty ~parents:[] ~contents:view
    >>= fun commit_id ->
    Store.of_commit_id task commit_id repo >>= fun store ->
    Tree.snapshot (store ())

  let remove_shadowed_by items map =
    List.fold_left (fun acc (_, name) ->
        StringMap.remove name acc
      ) map items

  let rec has_prefix ~prefix p =
    match prefix, p with
    | [], _ -> true
    | pre::pres, p::ps ->
      if pre = p then has_prefix ~prefix:pres ps
      else false
    | _, [] -> false

  (* Note: writing to a path removes it from [conflicts], if present *)
  let rw ~conflicts ~store view =
    let remove_conflict path = conflicts := PathSet.remove path !conflicts in
    let name_of_irmin_path = name_of_irmin_path ~root:"rw" in
    (* Keep track of which qids we're still using. We need to give the
       same qid to the client each time. TODO: use a weak map here. *)
    let nodes = Hashtbl.create 10 in

    let rec get ~dir (ty, leaf) =
      let hash_key = (ty, Path.rcons dir leaf) in
      try Hashtbl.find nodes hash_key
      with Not_found ->
        let inode = inode_of hash_key in
        Hashtbl.add nodes hash_key inode;
        inode

    and inode_of (ty, full_path) =
      match ty with
      | `Directory -> irmin_rw_dir full_path
      | `File ->
        let path = name_of_irmin_path full_path in
        let file = irmin_rw_file ~remove_conflict ~view full_path in
        Vfs.Inode.file path file

    and irmin_rw_dir path =
      let name = name_of_irmin_path path in
      (* Irmin doesn't store empty directories, so we need to store
         that list in the server's memory. Meet [extra_dirs]. *)
      let extra_dirs = ref empty_inode_map in
      let ls () =
        snapshot ~store view >>= fun root ->
        begin Tree.get_dir root path >>= function
          | None     -> Lwt.return []   (* in parent's extra_dirs? *)
          | Some dir -> Tree.ls dir
        end >>= fun items ->
        extra_dirs := remove_shadowed_by items !extra_dirs;
        let extra_inodes = StringMap.bindings !extra_dirs |> List.map snd in
        ok (extra_inodes @ List.map (get ~dir:path) items)
      in
      let mkfile name =
        let new_path = Path.rcons path name in
        View.update view new_path "" >|= fun () ->
        remove_conflict new_path;
        Ok (get ~dir:path (`File, name))
      in
      let lookup name =
        let real_result =
          snapshot ~store view >>= fun snapshot ->
          Tree.get_dir snapshot path >>= function
          | None -> err_enoent
          | Some dir ->
            Tree.ty dir name >>= function
            | `File
            | `Directory as ty -> ok (get ~dir:path (ty, name))
            | `None            -> err_enoent
        in
        real_result >|= function
        | Ok _ as ok   -> ok
        | Error _ as e ->
          try Ok (StringMap.find name !extra_dirs)
          with Not_found -> e
      in
      let mkdir name =
        lookup name >>= function
        | Ok _    -> err_already_exists name
        | Error _ ->
          let new_dir = get ~dir:path (`Directory, name) in
          extra_dirs := StringMap.add name new_dir !extra_dirs;
          remove_conflict (Irmin.Path.String_list.rcons path name);
          ok new_dir
      in
      let remove () =
        (* FIXME: is this correct? *)
        extra_dirs := StringMap.empty;
        conflicts := PathSet.filter (has_prefix ~prefix:path) !conflicts;
        View.remove_rec view path >>= ok
      in
      let rename _ = failwith "TODO" in
      Vfs.Dir.create ~ls ~mkfile ~mkdir ~lookup ~remove ~rename |>
      Vfs.Inode.dir name
    in
    irmin_rw_dir []

  let transactions_ctl ~merge ~remover = function
    | "close" -> Lazy.force remover >|= fun () -> Ok ""
    | "commit" ->
      begin merge () >>= function
        | Ok (`Ok ())        -> Lazy.force remover >|= fun () -> Ok ""
        | Ok (`Conflict msg) -> err_conflict msg
        | Error ename        -> Vfs.error "%s" ename
      end
    | x -> err_unknown_cmd x

  let string_of_parents parents =
    parents
    |> List.map (fun h -> Store.Hash.to_hum h ^ "\n")
    |> String.concat ""

  let format_conflicts conflicts =
    let lines =
      conflicts
      |> PathSet.elements
      |> List.map (fun n -> String.concat "/" n ^ "\n")
    in
    Cstruct.of_string (String.concat "" lines)

  let re_newline = Str.regexp_string "\n"
  let make_instance store ~remover _name =
    let path = [] in
    let msg_file, get_msg = Vfs.File.rw_of_string "" in
    View.of_path (store "view") path >|= fun view ->
    let parents = View.parents view |> string_of_parents in
    let parents_file, get_parents = Vfs.File.rw_of_string parents in
    let conflicts = ref PathSet.empty in
    (* Commit transaction *)
    let merge () =
      match !conflicts with
      | e when not (PathSet.is_empty e) ->
        Lwt.return (Error "conflicts file is not empty")
      | _ ->
        let parents = get_parents () |> Str.split re_newline in
        match List.map Store.Hash.of_hum parents with
        | exception Invalid_argument msg -> Lwt.return (Error msg)
        | parents ->
          let msg = match get_msg () with
            | "" -> "(no commit message)"
            | x -> x
          in
          let store = store msg in
          View.make_head store (Store.task store) ~parents ~contents:view
          >>= fun head ->
          Store.merge_head store head >|= fun x -> Ok x
    in
    (* Current state (will finish initialisation below) *)
    let contents = ref empty_inode_map in
    (* Files present in both normal and merge modes *)
    let stage = rw ~conflicts ~store view in
    let add inode = StringMap.add (Vfs.Inode.basename inode) inode in
    let ctl = Vfs.File.command (transactions_ctl ~merge ~remover) in
    let origin = Vfs.File.ro_of_string (Path.to_hum path) in
    let common =
      empty_inode_map
      |> add stage
      |> add (Vfs.Inode.file "msg"     msg_file)
      |> add (Vfs.Inode.file "parents" parents_file)
      |> add (Vfs.Inode.file "ctl"     ctl)
      |> add (Vfs.Inode.file "origin"  origin)
    in
    let rec normal_mode () =
      common
      |> add (Vfs.Inode.file "merge" (Vfs.File.command merge_mode))

    (* Merge mode *)
    and merge_mode commit_id =
      (* Check hash is valid *)
      let store = store "merge" in
      let repo = Store.repo store in
      match Store.Hash.of_hum commit_id with
      | exception _  -> err_invalid_commit_id commit_id
      | their_commit ->
        Store.Private.Commit.mem (Store.Private.Repo.commit_t repo) their_commit
        >>= function
        | false -> err_enoent
        | true ->
          let unit_task () = Irmin.Task.empty in
          Store.of_commit_id unit_task their_commit repo >>= fun theirs ->
          let theirs = theirs () in
          (* Add to parents *)
          let data = Cstruct.of_string (commit_id ^ "\n") in
          Vfs.File.size parents_file >>*= fun size ->
          Vfs.File.open_ parents_file >>*= fun fd ->
          Vfs.File.write fd ~offset:size data >>*= fun () ->
          (* Grab current "rw" dir as "ours" *)
          View.make_head store (Store.task store)
            ~parents:(View.parents view) ~contents:view
          >>= fun our_commit ->
          Store.of_commit_id unit_task our_commit repo >>= fun ours ->
          let ours = ours () in
          let ours_ro = read_only ~name:"ours" ours in
          let theirs_ro = read_only ~name:"theirs" theirs in
          begin Store.lcas_head ours ~n:1 their_commit >>= function
            | `Max_depth_reached | `Too_many_lcas -> assert false
            | `Ok [] -> Lwt.return (None, Vfs.Inode.dir "base" Vfs.Dir.empty)
            | `Ok (base::_) ->
              Store.of_commit_id unit_task base repo >|= fun s ->
              let s = s () in
              (Some s, read_only ~name:"base" s)
          end >>= fun (base, base_ro) ->
          Merge.merge ~ours ~theirs ~base view >>= fun merge_conflicts ->
          conflicts := PathSet.union !conflicts merge_conflicts;
          let conflicts_file =
            let read () = ok (Some (format_conflicts !conflicts)) in
            Vfs.File.of_kvro ~read:read
          in
          contents :=
            common
            |> add (Vfs.Inode.file "merge" (Vfs.File.command merge_mode))
            |> add (Vfs.Inode.file "conflicts" conflicts_file)
            |> add ours_ro
            |> add base_ro
            |> add theirs_ro;
          Lwt.return (Ok "ok")
    in
    contents := normal_mode ();
    Ok (Vfs.Dir.of_map_ref contents)

  let static_dir name items = Vfs.Inode.dir name (Vfs.Dir.of_list items)

  (* A stream file that initially Lwt.returns [str initial]. Further
     reads call [wait_for_change_from x], where [x] is the value
     previously Lwt.returned and then Lwt.return that, until the file
     is closed. *)
  let watch_stream ~initial ~wait_for_change_from ~str =
    let last_seen = ref initial in
    let data = ref (Cstruct.of_string (str initial)) in
    let read count =
      begin if Cstruct.len !data = 0 then (
          wait_for_change_from !last_seen >|= fun now ->
          last_seen := now;
          data := Cstruct.of_string (str now)
        ) else Lwt.return ()
      end >|= fun () ->
      let count = min count (Cstruct.len !data) in
      let response = Cstruct.sub !data 0 count in
      data := Cstruct.shift !data count;
      Ok (response)
    in
    let write _ = err_read_only in
    Vfs.File.Stream.create ~read ~write

  let head_stream store initial_head =
    let cond = Lwt_condition.create () in
    let current = ref initial_head in
    let () =
      let cb _diff =
        Store.head store >|= fun commit_id ->
        if commit_id <> !current then (
          current := commit_id;
          Lwt_condition.broadcast cond ()
        ) in
      let remove_watch =
        Store.watch_head store ?init:initial_head cb in
      ignore remove_watch in (* TODO *)
    let str = function
      | None -> "\n"
      | Some hash -> Store.Hash.to_hum hash ^ "\n" in
    let rec wait_for_change_from old =
      if old <> !current then Lwt.return !current
      else (
        Lwt_condition.wait cond >>= fun () ->
        wait_for_change_from old
      ) in
    watch_stream ~initial:initial_head ~wait_for_change_from ~str

  let head_live store =
    Vfs.File.of_stream (fun () ->
        Store.head store >|= fun initial_head ->
        head_stream store initial_head
      )

  let reflog_stream store =
    let stream, push = Lwt_stream.create () in
    let () =
      let cb = function
        | `Added x | `Updated (_, x) ->
          push (Some (Store.Hash.to_hum x ^ "\n"));
          Lwt.return ()
        | `Removed _ ->
          push (Some "\n");
          Lwt.return ()
      in
      let remove_watch = Store.watch_head store cb in
      ignore remove_watch (* TODO *)
    in
    let data = ref (Cstruct.create 0) in
    let read count =
      begin if Cstruct.len !data = 0 then (
          Lwt_stream.next stream >|= fun next ->
          data := Cstruct.of_string next
        ) else Lwt.return ()
      end >|= fun () ->
      let count = min count (Cstruct.len !data) in
      let response = Cstruct.sub !data 0 count in
      data := Cstruct.shift !data count;
      Ok (response)
    in
    let  write _ = err_read_only in
    Vfs.File.Stream.create ~read ~write

  let reflog store =
    Vfs.File.of_stream (fun () -> Lwt.return (reflog_stream store))

  let equal_ty a b =
    match a, b with
    | `None, `None -> true
    | `File a, `File b -> a = b
    | `Directory a, `Directory b -> Tree.equal a b
    | _ -> false

  let watch_tree_stream store ~path ~initial =
    let cond = Lwt_condition.create () in
    let current = ref initial in
    let () =
      let cb _diff =
        Tree.snapshot store >>= fun root ->
        Tree.node root path >|= fun node ->
        if not (equal_ty node !current) then (
          current := node;
          Lwt_condition.broadcast cond ()
        ) in
      let remove_watch =
        Store.watch_head store cb in
      ignore remove_watch in (* TODO *)
    let str = function
      | `None -> "\n"
      | `File hash -> "F-" ^ Store.Private.Contents.Key.to_hum hash ^ "\n"
      | `Directory dir ->
        match Tree.hash dir with
        | None -> "\n"
        | Some hash -> "D-" ^ Store.Private.Node.Key.to_hum hash ^ "\n" in
    let rec wait_for_change_from old =
      if not (equal_ty old !current) then Lwt.return !current
      else (
        Lwt_condition.wait cond >>= fun () ->
        wait_for_change_from old
      ) in
    watch_stream ~initial ~wait_for_change_from ~str

  let watch_tree store ~path =
    Vfs.File.of_stream (fun () ->
        Tree.snapshot store >>= fun snapshot ->
        Tree.node snapshot path >|= fun initial ->
        watch_tree_stream store ~path ~initial
      )

  let rec watch_dir store ~path =
    let live = lazy (Vfs.Inode.file "tree.live" (watch_tree store ~path)) in
    let cache = ref empty_inode_map in   (* Could use a weak map here *)
    let lookup name =
      try StringMap.find name !cache
      with Not_found ->
        let new_path = Path.rcons path name in
        let dir = watch_dir store ~path:new_path in
        let inode = Vfs.Inode.dir (name ^ ".node") dir in
        cache := StringMap.add name inode !cache;
        inode
    in
    let ls () =
      let to_inode x =
        match Path.rdecons x with
        | None -> assert false
        | Some (_, name) -> lookup name in
      Store.list store path >|= fun items ->
      Ok (Lazy.force live :: List.map to_inode items)
    in
    let lookup = function
      | "tree.live" -> ok (Lazy.force live)
      | x when Filename.check_suffix x ".node" ->
        ok (lookup (Filename.chop_suffix x ".node"))
      | _ -> err_enoent
    in
    let remove () = Vfs.Dir.err_read_only in
    Vfs.Dir.read_only ~ls ~lookup ~remove

  (* Note: can't use [Store.fast_forward_head] because it can
     sometimes return [false] on success (when already up-to-date). *)
  let fast_forward store commit_id =
    let store = store "Fast-forward" in
    Store.head store >>= fun old_head ->
    let do_ff () =
      Store.compare_and_set_head store ~test:old_head ~set:(Some commit_id) >|= function
      | true -> `Ok
      | false -> `Not_fast_forward in   (* (concurrent update) *)
    match old_head with
    | None -> do_ff ()
    | Some expected ->
      Store.lcas_head store commit_id >>= function
      | `Ok lcas ->
        if List.mem expected lcas then do_ff ()
        else Lwt.return `Not_fast_forward
      (* These shouldn't happen, because we didn't set any limits *)
      | `Max_depth_reached | `Too_many_lcas -> assert false

  let fast_forward_merge store =
    Vfs.File.command @@ fun hash ->
    match Store.Hash.of_hum hash with
    | exception ex -> err_invalid_hash hash ex
    | hash         ->
      fast_forward store hash >>= function
      | `Ok               -> ok ""
      | `Not_fast_forward -> err_not_fast_forward

  let status store () =
    Store.head (store "head") >|= function
    | None      -> "\n"
    | Some head -> Store.Hash.to_hum head ^ "\n"

  let transactions store =
    let lock = Lwt_mutex.create () in
    let items = ref StringMap.empty in
    let ls () = ok (StringMap.bindings !items |> List.map snd) in
    let lookup name =
      try ok (StringMap.find name !items)
      with Not_found -> err_enoent
    in
    let make = make_instance store in
    let remover name =
      lazy (
        Lwt_mutex.with_lock lock (fun () ->
            items := StringMap.remove name !items;
            Lwt.return_unit
          ))
    in
    let mkdir name =
      Lwt_mutex.with_lock lock (fun () ->
          if StringMap.mem name !items then Vfs.Dir.err_already_exists
          else (
            let remover = remover name in
            make ~remover name >>= function
            | Error _ as e -> Lwt.return e
            | Ok dir       ->
              if Lazy.is_val remover then err_enoent else (
                let inode = Vfs.Inode.dir name dir in
                items := StringMap.add name inode !items;
                ok inode
              )))
    in
    let mkfile _ = Vfs.Dir.err_dir_only in
    let rename _ _ = Vfs.Dir.err_read_only in   (* TODO *)
    let remove _ = Vfs.Dir.err_read_only in
    Vfs.Dir.create ~ls ~mkfile ~mkdir ~lookup ~remove ~rename

  let branch make_task ~remove repo name =
    let name = ref name in
    let remove () = remove !name in
    let make_contents name =
      Store.of_branch_id make_task name repo >|= fun store -> [
        read_only ~name:"ro" (store "ro");
        Vfs.Inode.dir  "transactions" (transactions store);
        Vfs.Inode.dir  "watch"        (watch_dir ~path:[] @@ store "watch");
        Vfs.Inode.file "head.live"    (head_live @@ store "watch");
        Vfs.Inode.file "fast-forward" (fast_forward_merge store);
        Vfs.Inode.file "reflog"       (reflog @@ store "watch");
        Vfs.Inode.file "head"         (Vfs.File.status @@ status store);
      ] in
    let contents = ref (make_contents !name) in
    let ls () = !contents >|= fun contents -> Ok contents in
    let lookup name =
      !contents >|= fun items ->
      let rec aux = function
        | [] -> Vfs.Error.noent
        | x :: _ when Vfs.Inode.basename x = name -> Ok x
        | _ :: xs -> aux xs in
      aux items
    in
    let i = Vfs.Dir.read_only ~ls ~lookup ~remove |> Vfs.Inode.dir !name in
    let renamed new_name =
      Vfs.Inode.set_basename i new_name;
      name := new_name;
      contents := make_contents new_name
    in
    (i, renamed)

  module StringSet = Set.Make(String)

  let branch_dir make_task repo =
    let cache = ref StringMap.empty in
    let remove name =
      Store.Repo.remove_branch repo name >|= fun () ->
      cache := StringMap.remove name !cache;
      Ok () in
    let get_via_cache name =
      try StringMap.find name !cache
      with Not_found ->
        let entry = branch ~remove make_task repo name in
        cache :=  StringMap.add name entry !cache;
        entry
    in
    let ls () =
      Store.Repo.branches repo >|= fun names ->
      let names =
        let names = StringSet.of_list names in
        StringMap.bindings !cache
        |> List.map fst
        |> StringSet.of_list
        |> StringSet.union names
        |> StringSet.elements
      in
      Ok (List.map (fun n -> fst (get_via_cache n)) names)
    in
    let lookup name =
      try ok (StringMap.find name !cache |> fst)
      with Not_found ->
        Store.Private.Ref.mem (Store.Private.Repo.ref_t repo) name >>= function
        | true  -> ok (get_via_cache name |> fst)
        | false -> err_enoent
    in
    let mkdir name = ok (get_via_cache name |> fst) in
    let remove () = Vfs.Dir.err_read_only in
    let rename inode new_name =
      (* TODO: some races here... *)
      let old_name = Vfs.Inode.basename inode in
      let refs = Store.Private.Repo.ref_t repo in
      Store.Private.Ref.mem refs new_name >>= function
      | true -> err_eisdir
      | false ->
        Store.Private.Ref.read refs old_name >>= fun head ->
        begin match head with
          | None      -> Lwt.return_unit
          | Some head -> Store.Private.Ref.update refs new_name head end
        >>= fun () ->
        Store.Private.Ref.remove refs old_name >>= fun () ->
        let entry = StringMap.find old_name !cache in
        snd entry new_name;
        cache :=
          !cache
          |> StringMap.remove old_name
          |> StringMap.add new_name entry;
        Lwt.return (Ok ())
    in
    Vfs.Dir.dir_only ~ls ~lookup ~mkdir ~remove ~rename

  (* /trees *)

  let tree_hash_of_hum h =
    let file h = `File (String.trim h |> Store.Private.Contents.Key.of_hum) in
    let dir h = `Dir (String.trim h |> Store.Private.Node.Key.of_hum) in
    try
      if h = "" then Ok `None
      else match String.sub h 0 2, String.sub h 2 (String.length h - 2) with
        | "F-", hash -> Ok (file hash)
        | "D-", hash -> Ok (dir hash)
        | _ -> Vfs.Error.noent
    with _ex ->
      Vfs.Error.noent

  let trees_dir _make_task repo =
    let inode_of_tree_hash name =
      Lwt.return (tree_hash_of_hum name) >>*= function
      | `File hash ->
        begin
          Store.Private.Contents.read (Store.Private.Repo.contents_t repo) hash
          >|= function
          | Some data -> Ok (Vfs.File.ro_of_string data |> Vfs.Inode.file name)
          | None      -> Vfs.Error.noent
        end
      | `None ->
        let root = Tree.of_dir_hash repo None in
        ok (ro_tree ~name:"ro" ~get_root:(fun () -> Lwt.return root))
      | `Dir hash ->
        let root = Tree.of_dir_hash repo (Some hash) in
        ok (ro_tree ~name:"ro" ~get_root:(fun () -> Lwt.return root))
    in
    let cache = ref StringMap.empty in   (* Could use a weak map here *)
    let ls () = ok [] in
    let lookup name =
      try ok (StringMap.find name !cache)
      with Not_found ->
        inode_of_tree_hash name >>*= fun inode ->
        cache := StringMap.add name inode !cache;
        ok inode
    in
    let remove () = Vfs.Dir.err_read_only in
    Vfs.Dir.read_only ~ls ~lookup ~remove

  (* /snapshots *)

  let parents_file store =
    let read () =
      let store = store "parents" in
      begin Store.head store >>= function
        | None -> Lwt.return []
        | Some head -> Store.history store ~depth:1 >|= fun hist ->
          Store.History.pred hist head
      end >|= fun parents ->
      Ok (Some (Cstruct.of_string (string_of_parents parents))) in
    Vfs.File.of_kvro ~read

  let snapshot_dir store name =
    static_dir name [
      read_only ~name:"ro"     (store "ro");
      Vfs.Inode.file "hash"    (Vfs.File.ro_of_string name);
      Vfs.Inode.file "parents" (parents_file store)
    ]

  let snapshots_dir make_task repo =
    let cache = ref empty_inode_map in   (* Could use a weak map here *)
    let ls () = ok [] in
    let lookup name =
      try ok (StringMap.find name !cache)
      with Not_found ->
        begin
          try ok (Store.Hash.of_hum name)
          with _ex -> err_invalid_commit_id name
        end >>*= fun commit_id ->
        Store.Private.Commit.mem (Store.Private.Repo.commit_t repo) commit_id
        >>= function
        | false -> err_enoent
        | true ->
          Store.of_commit_id make_task commit_id repo >|= fun store ->
          let inode = snapshot_dir store name in
          cache := StringMap.add name inode !cache;
          Ok inode
    in
    let remove () = Vfs.Dir.err_read_only in
    Vfs.Dir.read_only ~ls ~lookup ~remove

  let create make_task repo =
    Vfs.Dir.of_list [
      Vfs.Inode.dir "branch"    (branch_dir make_task repo);
      Vfs.Inode.dir "trees"     (trees_dir make_task repo);
      Vfs.Inode.dir "snapshots" (snapshots_dir make_task repo);
      Vfs.Inode.dir "remotes"   (Remote.create make_task repo);
    ]

end