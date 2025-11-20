class Plocate < Formula
  desc "Much faster locate based on posting lists"
  homepage "https://plocate.sesse.net/"
  url "https://plocate.sesse.net/download/plocate-1.1.23.tar.gz"
  sha256 "06bd3b284d5d077b441bef74edb0cc6f8e3f0a6f58b4c15ef865d3c460733783"
  license "GPL-2.0-or-later"

  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkg-config" => :build
  depends_on "zstd"

  def install
    system "meson", "setup", "build", *std_meson_args
    system "meson", "compile", "-C", "build"
    system "meson", "install", "-C", "build"
  end

  test do
    # Test that plocate can be executed and shows version/help
    assert_match "plocate", shell_output("#{bin}/plocate --help 2>&1", 1)
    # Test plocate-build exists
    assert_match "plocate-build", shell_output("#{sbin}/plocate-build --help 2>&1", 1)
  end
end
