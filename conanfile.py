from conan import ConanFile
from conan.tools.cmake import CMake, CMakeDeps, CMakeToolchain

class TdlibConan(ConanFile):
	name = "tdlib-repo"
	version = "1.0"

	settings = "os", "arch", "compiler", "build_type"
	generators = "CMakeDeps", "CMakeToolchain"

	requires = (
		"openssl/1.1.1w",
		"zlib/1.2.13"
	)

	options = {"shared": [True, False]}
	default_options = {"shared": False}

    def layout(self):
        cmake_layout(self, build_folder="build/conan")

	def generate(self):
		tc = CMakeToolchain(self)
		# keep install prefix controlled by CMakePresets.json
		tc.generate()
		deps = CMakeDeps(self)
		deps.generate()

# We intentionally don't implement build() to force user to use CMake presets
# The conanfile is used to fetch and provide dependencies via CMakeToolchain + CMakeDeps
