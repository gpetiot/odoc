(* Packages *)

type dep = string * Digest.t

(* type id = Odoc.id *)

type intf = { mif_hash : string; mif_path : Fpath.t; mif_deps : dep list }

let pp_intf fmt (i : intf) =
  Format.fprintf fmt "@[<hov>{@,mif_hash: %s;@,mif_path: %a;@,mif_deps: %a@,}@]"
    i.mif_hash Fpath.pp i.mif_path
    (Fmt.Dump.list (Fmt.Dump.pair Fmt.string Fmt.string))
    i.mif_deps

type src_info = { src_path : Fpath.t }

let pp_src_info fmt i =
  Format.fprintf fmt "@[<hov>{@,src_path: %a@,}@]" Fpath.pp i.src_path
type impl = {
  mip_path : Fpath.t;
  mip_src_info : src_info option;
  mip_deps : dep list;
}

let pp_impl fmt i =
  Format.fprintf fmt
    "@[<hov>{@,mip_path: %a;@,mip_src_info: %a;@,mip_deps: %a@,}@]" Fpath.pp
    i.mip_path
    (Fmt.Dump.option pp_src_info)
    i.mip_src_info
    (Fmt.Dump.list (Fmt.Dump.pair Fmt.string Fmt.string))
    i.mip_deps

type modulety = {
  m_name : string;
  m_intf : intf;
  m_impl : impl option;
  m_hidden : bool;
}

let pp_modulety fmt i =
  Format.fprintf fmt
    "@[<hov>{@,m_name: %s;@,m_intf: %a;@,m_impl: %a;@,m_hidden: %b@,}@]"
    i.m_name pp_intf i.m_intf (Fmt.Dump.option pp_impl) i.m_impl i.m_hidden

type mld = { mld_path : Fpath.t; mld_rel_path : Fpath.t }

let pp_mld fmt m =
  Format.fprintf fmt "@[<hov>{@,mld_path: %a;@,mld_rel_path: %a@,}@]" Fpath.pp
    m.mld_path Fpath.pp m.mld_rel_path

type asset = { asset_path : Fpath.t; asset_rel_path : Fpath.t }

let pp_asset fmt m =
  Format.fprintf fmt "@[<hov>{@,asset_path: %a;@,asset_rel_path: %a@,}@]"
    Fpath.pp m.asset_path Fpath.pp m.asset_rel_path

type libty = {
  lib_name : string;
  dir : Fpath.t;
  archive_name : string option;
  lib_deps : Util.StringSet.t;
  modules : modulety list;
}

let pp_libty fmt l =
  Format.fprintf fmt
    "@[<hov>{@,\
     lib_name: %s;@,\
     dir: %a;@,\
     archive_name: %a;@,\
     lib_deps: %a;@,\
     modules: %a@,\
     }@]"
    l.lib_name Fpath.pp l.dir
    (Fmt.Dump.option Fmt.string)
    l.archive_name (Fmt.Dump.list Fmt.string)
    (Util.StringSet.elements l.lib_deps)
    (Fmt.Dump.list pp_modulety)
    l.modules

type t = {
  name : string;
  version : string;
  libraries : libty list;
  mlds : mld list;
  assets : asset list;
  other_docs : Fpath.Set.t;
  pkg_dir : Fpath.t;
  config : Global_config.t;
}

let pp fmt t =
  Format.fprintf fmt
    "@[<hov>{@,\
     name: %s;@,\
     version: %s;@,\
     libraries: %a;@,\
     mlds: %a;@,\
     assets: %a;@,\
     other_docs: %a;@,\
     pkg_dir: %a@,\
     }@]"
    t.name t.version (Fmt.Dump.list pp_libty) t.libraries (Fmt.Dump.list pp_mld)
    t.mlds (Fmt.Dump.list pp_asset) t.assets (Fmt.Dump.list Fpath.pp)
    (Fpath.Set.elements t.other_docs)
    Fpath.pp t.pkg_dir

let maybe_prepend_top top_dir dir =
  match top_dir with None -> dir | Some d -> Fpath.(d // dir)

let pkg_dir top_dir pkg_name = maybe_prepend_top top_dir Fpath.(v pkg_name)

module Module = struct
  type t = modulety

  let pp ppf (t : t) =
    Fmt.pf ppf "name: %s@.intf: %a@.impl: %a@.hidden: %b@." t.m_name Fpath.pp
      t.m_intf.mif_path (Fmt.option pp_impl) t.m_impl t.m_hidden

  let is_hidden name = Astring.String.is_infix ~affix:"__" name

  let vs libsdir cmtidir modules =
    let dir = match cmtidir with None -> libsdir | Some dir -> dir in
    let mk m_name =
      let exists ext =
        let p =
          Fpath.(dir // add_ext ext (v (String.uncapitalize_ascii m_name)))
        in
        let upperP =
          Fpath.(dir // add_ext ext (v (String.capitalize_ascii m_name)))
        in
        Logs.debug (fun m ->
            m "Checking %a (then %a)" Fpath.pp p Fpath.pp upperP);
        match Bos.OS.File.exists p with
        | Ok true -> Some p
        | _ -> (
            match Bos.OS.File.exists upperP with
            | Ok true -> Some upperP
            | _ -> None)
      in
      let mk_intf mif_path =
        match Odoc.compile_deps mif_path with
        | Ok { digest; deps } ->
            { mif_hash = digest; mif_path; mif_deps = deps }
        | Error _ -> failwith "bad deps"
      in
      let mk_impl mip_path =
        (* Directories in which we should look for source files *)
        let src_dirs =
          match cmtidir with None -> [ libsdir ] | Some d2 -> [ libsdir; d2 ]
        in

        let mip_src_info =
          match Ocamlobjinfo.get_source mip_path src_dirs with
          | None ->
              Logs.debug (fun m -> m "No source found for module %s" m_name);
              None
          | Some src_path ->
              Logs.debug (fun m ->
                  m "Found source file %a for %s" Fpath.pp src_path m_name);
              Some { src_path }
        in
        let mip_deps =
          match Odoc.compile_deps mip_path with
          | Ok { digest = _; deps } -> deps
          | Error _ -> failwith "bad deps"
        in
        { mip_src_info; mip_path; mip_deps }
      in
      let state = (exists "cmt", exists "cmti") in

      let m_hidden = is_hidden m_name in
      try
        let r (m_intf, m_impl) = Some { m_name; m_intf; m_impl; m_hidden } in
        match state with
        | Some cmt, Some cmti -> r (mk_intf cmti, Some (mk_impl cmt))
        | Some cmt, None -> r (mk_intf cmt, Some (mk_impl cmt))
        | None, Some cmti -> r (mk_intf cmti, None)
        | None, None ->
            Logs.info (fun m -> m "No files for module: %s" m_name);
            None
      with _ ->
        Logs.err (fun m -> m "Error processing module %s. Ignoring." m_name);
        None
    in

    Eio.Fiber.List.filter_map mk modules
end

module Lib = struct
  let handle_virtual_lib ~dir ~lib_name ~all_lib_deps =
    let modules =
      match
        Bos.OS.Dir.fold_contents
          (fun p acc ->
            if Fpath.has_ext "cmti" p then
              let m_name = Fpath.rem_ext p |> Fpath.basename in
              m_name :: acc
            else acc)
          [] dir
      with
      | Ok x -> x
      | Error (`Msg e) ->
          Logs.err (fun m -> m "Error reading dir %a: %s" Fpath.pp dir e);
          []
    in
    let modules = Module.vs dir None modules in
    let lib_deps =
      try Util.StringMap.find lib_name all_lib_deps
      with _ -> Util.StringSet.empty
    in
    [ { lib_name; archive_name = None; modules; lib_deps; dir } ]

  let v ~libname_of_archive ~pkg_name ~dir ~cmtidir ~all_lib_deps ~cmi_only_libs
      =
    Logs.debug (fun m ->
        m "Classifying dir %a for package %s" Fpath.pp dir pkg_name);
    let dirs =
      match cmtidir with None -> [ dir ] | Some dir2 -> [ dir; dir2 ]
    in
    let results = Odoc.classify dirs in
    match List.length results with
    | 0 -> (
        match
          List.find_opt (fun dir -> List.mem_assoc dir cmi_only_libs) dirs
        with
        | None -> []
        | Some dir ->
            let lib_name = List.assoc dir cmi_only_libs in
            handle_virtual_lib ~dir ~lib_name ~all_lib_deps)
    | _ ->
        Logs.debug (fun m -> m "Got %d lines" (List.length results));
        List.filter_map
          (fun (archive_name, modules) ->
            match
              Fpath.Map.find Fpath.(dir / archive_name) libname_of_archive
            with
            | Some lib_name ->
                let modules = Module.vs dir cmtidir modules in
                let lib_deps =
                  try Util.StringMap.find lib_name all_lib_deps
                  with _ -> Util.StringSet.empty
                in
                Some
                  {
                    lib_name;
                    archive_name = Some archive_name;
                    modules;
                    lib_deps;
                    dir;
                  }
            | None ->
                Logs.info (fun m ->
                    m "Unable to determine library of archive %s: Ignoring."
                      archive_name);
                None)
          results

  let pp ppf t =
    Fmt.pf ppf "archive: %a modules: [@[<hov 2>@,%a@]@,]"
      Fmt.(option string)
      t.archive_name
      Fmt.(list ~sep:sp Module.pp)
      t.modules
end

(* Construct the list of mlds and assets from a package name and its list of pages *)
let mk_mlds pkg_name odoc_pages =
  let odig_convention asset_path =
    let asset_prefix =
      Fpath.(v (Opam.prefix ()) / "doc" / pkg_name / "odoc-assets")
    in
    let rel_path = Fpath.rem_prefix asset_prefix asset_path in
    match rel_path with
    | None -> []
    | Some rel_path ->
        [ { asset_path; asset_rel_path = Fpath.(v "_assets" // rel_path) } ]
  in
  let prefix = Fpath.(v (Opam.prefix ()) / "doc" / pkg_name / "odoc-pages") in
  let mlds, assets =
    Fpath.Set.fold
      (fun path (mld_acc, asset_acc) ->
        let rel_path = Fpath.rem_prefix prefix path in
        match rel_path with
        | None -> (mld_acc, odig_convention path @ asset_acc)
        | Some rel_path ->
            if Fpath.has_ext "mld" path then
              ( { mld_path = path; mld_rel_path = rel_path } :: mld_acc,
                asset_acc )
            else
              ( mld_acc,
                { asset_path = path; asset_rel_path = rel_path } :: asset_acc ))
      odoc_pages ([], [])
  in
  (mlds, assets)

let of_libs ~packages_dir libs =
  let Ocamlfind.Db.
        { archives_by_dir; libname_of_archive; cmi_only_libs; all_lib_deps; _ }
      =
    Ocamlfind.Db.create libs
  in

  (* Opam gives us a map of packages to directories, and vice-versa *)
  let opam_map, opam_rmap = Opam.pkg_to_dir_map () in

  (* Now we can construct the packages *)
  Fpath.Map.fold
    (fun dir archives acc ->
      match Fpath.Map.find dir opam_rmap with
      | None ->
          Logs.debug (fun m -> m "No package for dir %a\n%!" Fpath.pp dir);
          acc
      | Some pkg ->
          let libraries =
            Lib.v ~libname_of_archive ~pkg_name:pkg.name ~dir ~cmtidir:None
              ~all_lib_deps ~cmi_only_libs
          in
          let libraries =
            List.filter
              (fun l ->
                match l.archive_name with
                | None -> true
                | Some a -> Util.StringSet.mem a archives)
              libraries
          in
          Util.StringMap.update pkg.name
            (function
              | Some pkg ->
                  let libraries = libraries @ pkg.libraries in
                  Some { pkg with libraries }
              | None ->
                  let pkg_dir = pkg_dir packages_dir pkg.name in
                  let config = Global_config.load pkg.name in
                  let pkg', { Opam.odoc_pages; other_docs; _ } =
                    List.find
                      (fun (pkg', _) ->
                        (* Logs.debug (fun m ->
                            m "Checking %s against %s" pkg.Opam.name pkg'.Opam.name); *)
                        pkg = pkg')
                      opam_map
                  in
                  let mlds, assets = mk_mlds pkg'.name odoc_pages in
                  Logs.debug (fun m ->
                      m "%d mlds for package %s (from %d odoc_pages)"
                        (List.length mlds) pkg.name
                        (Fpath.Set.cardinal odoc_pages));
                  Some
                    {
                      name = pkg.name;
                      version = pkg.version;
                      libraries;
                      mlds;
                      assets;
                      other_docs;
                      pkg_dir;
                      config;
                    })
            acc)
    archives_by_dir Util.StringMap.empty

let of_packages ~packages_dir packages =
  let deps =
    if packages = [] then Opam.all_opam_packages () else Opam.deps packages
  in

  let Ocamlfind.Db.{ libname_of_archive; cmi_only_libs; all_lib_deps; _ } =
    Ocamlfind.Db.create (Ocamlfind.all () |> Util.StringSet.of_list)
  in

  let opam_map, _opam_rmap = Opam.pkg_to_dir_map () in

  let ps =
    List.filter_map
      (fun pkg -> List.find_opt (fun (pkg', _) -> pkg = pkg') opam_map)
      deps
  in

  let orig =
    List.filter_map
      (fun pkg ->
        List.find_opt (fun (pkg', _) -> pkg = pkg'.Opam.name) opam_map)
      packages
  in

  let all = orig @ ps in

  List.fold_left
    (fun acc (pkg, files) ->
      let libraries =
        List.fold_left
          (fun acc dir ->
            Lib.v ~libname_of_archive ~pkg_name:pkg.Opam.name ~dir ~cmtidir:None
              ~all_lib_deps ~cmi_only_libs
            @ acc)
          []
          (files.Opam.libs |> Fpath.Set.to_list)
      in
      let pkg_dir = pkg_dir packages_dir pkg.name in
      let config = Global_config.load pkg.name in
      let odoc_pages = files.Opam.odoc_pages in
      let other_docs = files.Opam.other_docs in
      let mlds, assets = mk_mlds pkg.name odoc_pages in
      Logs.debug (fun m ->
          m "%d mlds for package %s (from %d odoc_pages)" (List.length mlds)
            pkg.name
            (Fpath.Set.cardinal odoc_pages));
      Util.StringMap.add pkg.name
        {
          name = pkg.name;
          version = pkg.version;
          libraries;
          mlds;
          assets;
          other_docs;
          pkg_dir;
          config;
        }
        acc)
    Util.StringMap.empty all

(* Now we can construct the packages *)

type set = t Util.StringMap.t
