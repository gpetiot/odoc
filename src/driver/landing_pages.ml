open Packages
open Odoc_unit

let fpf = Format.fprintf

let make_unit ~odoc_dir ~odocl_dir ~mld_dir ~output_dir rel_path ~content
    ?(include_dirs = Fpath.Set.empty) ~pkgname ~pkg_args () =
  let input_file = Fpath.(mld_dir // rel_path / "index.mld") in
  let odoc_file = Fpath.(odoc_dir // rel_path / "page-index.odoc") in
  let odocl_file = Fpath.(odocl_dir // rel_path / "page-index.odocl") in
  Util.with_out_to input_file (fun oc ->
      fpf (Format.formatter_of_out_channel oc) "%t@?" content)
  |> Result.get_ok;
  let parent_id = rel_path |> Odoc.Id.of_fpath in
  {
    parent_id;
    odoc_dir;
    input_file;
    output_dir;
    odoc_file;
    odocl_file;
    pkg_args;
    pkgname;
    include_dirs;
    index = None;
    kind = `Mld;
  }

module PackageLanding = struct
  let content pkg ppf =
    fpf ppf "{0 %s}\n" pkg.name;
    if not (List.is_empty pkg.mlds) then
      fpf ppf
        "{1 Documentation pages}@\n@\n{{!/%s/doc/index}Documentation for %s}@\n"
        pkg.name pkg.name;
    if not (List.is_empty pkg.libraries) then
      fpf ppf "{1 Libraries}@\n@\n{{!/%s/lib/index}Libraries for %s}@\n"
        pkg.name pkg.name

  let page ~odoc_dir ~odocl_dir ~mld_dir ~output_dir ~pkg =
    let content = content pkg in
    let rel_path = pkg.pkg_dir in
    let pages_rel = [ (pkg.name, rel_path) ] in
    let pkg_args =
      {
        Pkg_args.pages = pages_rel;
        libs = [];
        compile_dir = output_dir;
        link_dir = odocl_dir;
      }
    in
    make_unit ~odoc_dir ~odocl_dir ~mld_dir ~output_dir rel_path ~content
      ~pkgname:pkg.name ~pkg_args ()
end

module PackageList = struct
  let content all ppf =
    let sorted_packages =
      all |> List.sort (fun n1 n2 -> String.compare n1.name n2.name)
    in
    fpf ppf "{0 List of all packages}@\n";
    let print_pkg pkg =
      fpf ppf "- {{!/__driver/%s/index}%s}@\n" pkg.name pkg.name
    in
    List.iter print_pkg sorted_packages

  let page ~mld_dir ~odoc_dir ~odocl_dir ~output_dir all =
    let content = content all in
    let rel_path = Fpath.v "./" in
    let pkgname = "__driver" in
    let pages_rel = [ (pkgname, rel_path) ] in
    let pkg_args =
      {
        Pkg_args.pages = pages_rel;
        libs = [];
        compile_dir = output_dir;
        link_dir = odocl_dir;
      }
    in
    make_unit ~odoc_dir ~odocl_dir ~mld_dir ~output_dir ~content ~pkgname
      ~pkg_args rel_path ()
end

module LibraryLanding = struct
  let content lib ppf =
    fpf ppf "{0 %s}@\n" lib.lib_name;
    let print_module m =
      if not m.m_hidden then fpf ppf "- {!%s}@\n" m.Packages.m_name
    in
    List.iter print_module lib.modules

  let page ~pkg ~odoc_dir ~odocl_dir ~mld_dir ~output_dir ~pkg_dir lib =
    let content = content lib in
    let rel_path = Fpath.(pkg_dir / "lib" / lib.lib_name) in
    let pages_rel = [ (pkg.name, rel_path) ] in
    let pkg_args =
      {
        Pkg_args.pages = pages_rel;
        libs = [];
        link_dir = odocl_dir;
        compile_dir = output_dir;
      }
    in
    let include_dirs = Fpath.Set.singleton Fpath.(odoc_dir // rel_path) in
    make_unit ~odoc_dir ~odocl_dir ~mld_dir ~output_dir rel_path ~content
      ~pkgname:pkg.name ~include_dirs ~pkg_args ()
end

module PackageLibLanding = struct
  let content pkg ppf =
    fpf ppf "{0 %s}@\n" pkg.name;
    let print_lib (lib : Packages.libty) =
      fpf ppf "- {{!/%s/%s/index}%s}@\n" pkg.name lib.lib_name lib.lib_name
    in
    List.iter print_lib pkg.libraries

  let page ~pkg ~odoc_dir ~odocl_dir ~mld_dir ~output_dir =
    let content = content pkg in
    let rel_path = Fpath.(pkg.pkg_dir / "lib") in
    let pages_rel = [ (pkg.name, rel_path) ] in
    let pkg_args =
      {
        Pkg_args.pages = pages_rel;
        libs = [];
        compile_dir = output_dir;
        link_dir = odocl_dir;
      }
    in
    make_unit ~odoc_dir ~odocl_dir ~mld_dir ~output_dir rel_path ~content
      ~pkgname:pkg.name ~pkg_args ()
end

let of_package ~mld_dir ~odoc_dir ~odocl_dir ~output_dir pkg =
  let library_pages =
    List.map
      (LibraryLanding.page ~pkg ~odoc_dir ~odocl_dir ~mld_dir
         ~pkg_dir:pkg.pkg_dir ~output_dir)
      pkg.libraries
  in
  let package_landing_page =
    PackageLanding.page ~odoc_dir ~odocl_dir ~mld_dir ~output_dir ~pkg
  in
  let library_list_page =
    PackageLibLanding.page ~odoc_dir ~odocl_dir ~mld_dir ~output_dir ~pkg
  in
  package_landing_page :: library_list_page :: library_pages

let of_packages ~mld_dir ~odoc_dir ~odocl_dir ~output_dir all =
  PackageList.page ~mld_dir ~odoc_dir ~odocl_dir ~output_dir all
  :: List.concat_map (of_package ~mld_dir ~odoc_dir ~odocl_dir ~output_dir) all
