from conan import ConanFile
from conan.tools.cmake import CMakeDeps, CMakeToolchain


class TdPackConan(ConanFile):
    name = "td-pack"
    version = "1.0.0"
    settings = "os", "compiler", "build_type", "arch"

    requires = (
        "openssl/1.1.1w",
        "zlib/1.3.1",
    )

    def config_options(self):
        # OpenSSL static-only, no tests
        self.options["openssl"].shared = False
        self.options["openssl"].no_tests = True
        self.options["zlib"].shared = False

    def configure(self):
        # Windows: disable asm (matches old Bazel config: no-asm)
        if self.settings.os == "Windows":
            self.options["openssl"].no_asm = True

        # iOS: disable features that aren't available (matches old Bazel config)
        if self.settings.os == "iOS":
            self.options["openssl"].no_comp = True
            self.options["openssl"].no_engine = True
            self.options["openssl"].no_async = True

    def generate(self):
        deps = CMakeDeps(self)
        deps.generate()
        tc = CMakeToolchain(self)
        tc.generate()
