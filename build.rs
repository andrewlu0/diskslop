fn main() {
    cc::Build::new()
        .file("mac/Trash.m")
        .file("mac/ScanPolicy.m")
        .flag("-fobjc-arc")
        .compile("native_trash");
    println!("cargo:rerun-if-changed=mac/Trash.m");
    println!("cargo:rerun-if-changed=mac/ScanPolicy.m");
    println!("cargo:rustc-link-lib=framework=Foundation");
}
