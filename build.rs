fn main() {
    cc::Build::new()
        .file("mac/Trash.m")
        .flag("-fobjc-arc")
        .compile("native_trash");
    println!("cargo:rerun-if-changed=mac/Trash.m");
    println!("cargo:rustc-link-lib=framework=Foundation");
}
