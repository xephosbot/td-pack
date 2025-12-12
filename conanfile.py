from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, CMakeDeps, cmake_layout

class TdLibRecipe(ConanFile):
    name = "tdlib-repo"
    version = "1.0"
    settings = "os", "arch", "compiler", "build_type"
    generators = ("CMakeDeps", "CMakeToolchain")

    def requirements(self):
        self.requires("openssl/1.1.1w")
        self.requires("zlib/1.3.1")

    def layout(self):
        cmake_layout(self, build_folder="build/conan")

    def generate(self):
        tc = CMakeToolchain(self)
        tc.cache_variables["CMAKE_INSTALL_PREFIX"] = f"{self.source_folder}/tdlib/{self.settings.os}/{self.settings.arch}"
        tc.cache_variables["TD_INSTALL_SHARED_LIBRARIES"] = "ON"
        tc.cache_variables["TD_INSTALL_STATIC_LIBRARIES"] = "ON"
        tc.cache_variables["TD_ENABLE_JNI"] = "OFF"
        tc.cache_variables["TD_ENABLE_LTO"] = "OFF"
        tc.cache_variables["TD_ENABLE_TESTS"] = "OFF"
        tc.cache_variables["TD_ENABLE_BENCHMARKS"] = "OFF"
        tc.generate()
    
        deps = CMakeDeps(self)
        deps.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()
