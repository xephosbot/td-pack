from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, CMakeDeps, cmake_layout

class TdLibRecipe(ConanFile):
    name = "tdlib-repo"
    version = "1.0"
    settings = "os", "arch", "compiler", "build_type"

    def build_requirements(self):
        self.tool_requires("cmake/[>=3.31]")

    def requirements(self):
        self.requires("openssl/3.3.0")
        self.requires("zlib/1.3.1")

    def layout(self):
        cmake_layout(self, build_folder="build/conan")

    def generate(self):
        tc = CMakeToolchain(self)
        tc.user_presets_path = "ConanPresets.json"
        tc.generate()
    
        deps = CMakeDeps(self)
        deps.generate()

    def configure(self):
        self.options["openssl"].shared = False
        self.options["zlib"].shared = False

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()
