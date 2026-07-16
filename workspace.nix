# CppNix, ported from Meson to languages.cc. Each meson subproject becomes a library
# target; the meson machinery becomes: sweeps (source lists), public blocks
# (deps_public / installed headers), configHeaders (configure_file + compiler checks),
# and generate (custom_target: bison, flex, and the R"__NIX_STR()" embeds). Feature
# tri-states became the booleans below; dependency() version floors became this
# workspace's pinned nixpkgs.
{ pkgs, lib, ... }:
let
  version = lib.removeSuffix "\n" (builtins.readFile ./.version);

  # Meson's gen_header generator, as two lines of the host language: wrap a committed
  # file in a C++ raw-string literal, so `#include "<name>.gen.hh"` splices it in.
  # Declaring the file as the step's input puts it in the target's pruned tree, so an
  # edit to it rebuilds exactly this target.
  embedAs = name: file: {
    command = ''{ echo 'R"__NIX_STR(' && cat ${lib.escapeShellArg file} && echo ')__NIX_STR"'; } > "$gen/${name}.gen.hh"'';
    inputs = [ file ];
    outputs = [ "${name}.gen.hh" ];
  };
  embed = file: embedAs (baseNameOf file) file;
  embeds = files: lib.listToAttrs (map (f: lib.nameValuePair (baseNameOf f) (embed f)) files);

  # Meson feature options, collapsed to the booleans they were guarding.
  withGC = true; # -Dgc=enabled
  withSeccomp = true; # -Dseccomp-sandboxing=enabled
  withCpuid = true; # -Dcpuid=enabled (x86_64)
  withMarkdown = true; # -Dmarkdown=enabled (lowdown)
in
{
  languages.cc = {
    enable = true;
    src = ./.;
    std.cpp = "c++23";

    # ---- nix-util -------------------------------------------------------------------
    libraries.nixutil = {
      srcs = [ "src/libutil" ];
      exclude = [
        "src/libutil/freebsd"
        "src/libutil/windows"
      ];
      public.headers = [
        "src/libutil/include"
        "src/libutil/unix/include"
        "src/libutil/linux/include"
      ];
      # nlohmann_json and libarchive are nix-util's public deps in meson; boost is
      # header-mostly but links context/coroutine/iostreams/url (no .pc, so `links`).
      public.deps = [
        pkgs.nlohmann_json
        pkgs.libarchive
        pkgs.boost
      ];
      deps = [
        pkgs.libblake3
        pkgs.openssl
        pkgs.libsodium
        pkgs.brotli
        pkgs.zstd
      ]
      ++ lib.optionals withCpuid [ pkgs.libcpuid ];
      links = [
        "boost_context"
        "boost_coroutine"
        "boost_iostreams"
        "boost_url"
      ];
      # The vendored widechar_width.h fallback: the sandbox never has a system copy.
      headers = [ "src/libutil/widecharwidth" ];
      inherit version;

      configHeaders."nix/util/config.hh" = {
        public = true;
        values.NIX_UBSAN_ENABLED = 0;
      };
      configHeaders."util-config-private.hh" = {
        values.HAVE_LIBCPUID = withCpuid;
        probes.HAVE_POSIX_FALLOCATE.function = "posix_fallocate";
      };
      configHeaders."util-unix-config-private.hh".probes = {
        HAVE_DECL_AT_SYMLINK_NOFOLLOW = {
          symbol = "AT_SYMLINK_NOFOLLOW";
          headers = [ "fcntl.h" ];
        };
        HAVE_F_GETPATH = {
          symbol = "F_GETPATH";
          headers = [ "fcntl.h" ];
        };
        HAVE_CLOSE_RANGE.function = "close_range";
        HAVE_LUTIMES.function = "lutimes";
        HAVE_PIPE2.function = "pipe2";
        HAVE_STRSIGNAL.function = "strsignal";
        HAVE_SYSCONF.function = "sysconf";
        HAVE_UTIMENSAT.function = "utimensat";
      };
    };

    # ---- nix-store ------------------------------------------------------------------
    libraries.nixstore = {
      srcs = [ "src/libstore" ];
      exclude = [
        "src/libstore/darwin"
        "src/libstore/freebsd"
        "src/libstore/windows"
        # -Ds3-aws-auth=disabled: the one meson feature this port turns off.
        "src/libstore/aws-creds.cc"
      ];
      public.headers = [
        "src/libstore/include"
        "src/libstore/unix/include"
        "src/libstore/linux/include"
      ];
      public.deps = [ ":nixutil" ];
      # Meson's implicit '.' include plus the per-platform build/ roots: sources say
      # "build/derivation-check.hh" and "derivation-builder-impl.hh".
      headers = [
        "src/libstore"
        "src/libstore/unix/build"
        "src/libstore/linux/build"
      ];
      deps = [
        pkgs.curl
        pkgs.sqlite
        pkgs.nlohmann_json
        pkgs.boost
      ]
      ++ lib.optionals withSeccomp [ pkgs.libseccomp ];
      links = [
        "boost_container"
        "boost_url"
      ];
      inherit version;

      generate = embeds [
        "src/libstore/schema.sql"
        "src/libstore/ca-specific-schema.sql"
      ];

      configHeaders."nix/store/config.hh" = {
        public = true;
        values.NIX_WITH_AWS_AUTH = false;
        values.NIX_LOCAL_SYSTEM = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-${pkgs.stdenv.hostPlatform.parsed.kernel.name}";
        probes.NIX_SUPPORT_ACL.compiles = ''
          #include <sys/xattr.h>
          int main(void) { (void) (void *) llistxattr; (void) (void *) lremovexattr; return 0; }
        '';
      };
      configHeaders."store-config-private.hh" = {
        values = {
          PACKAGE_VERSION = version;
          HAVE_SECCOMP = withSeccomp;
          HAVE_EMBEDDED_SANDBOX_SHELL = false;
          SANDBOX_SHELL = "${pkgs.busybox}/bin/busybox";
          LSOF = "${pkgs.lsof}/bin/lsof";
          NIX_STORE_DIR = "/nix/store";
          NIX_STATE_DIR = "/nix/var/nix";
          NIX_LOG_DIR = "/nix/var/log/nix";
          NIX_CONF_DIR = "/etc/nix";
        };
        probes = {
          CAN_LINK_SYMLINK.script = "ln -s ./nothing s && ln s l";
          HAVE_POSIX_FALLOCATE.function = "posix_fallocate";
          HAVE_STATVFS.function = "statvfs";
          HAVE_OPEN_TREE.function = "open_tree";
          HAVE_MOVE_MOUNT.function = "move_mount";
          HAVE_LANDLOCK.header = "linux/landlock.h";
        };
      };
    };

    # ---- nix-fetchers ---------------------------------------------------------------
    libraries.nixfetchers = {
      srcs = [ "src/libfetchers" ];
      public.headers = [ "src/libfetchers/include" ];
      public.deps = [
        ":nixutil"
        ":nixstore"
      ];
      deps = [
        pkgs.libgit2
        pkgs.nlohmann_json
      ];
      inherit version;
    };

    # ---- nix-expr -------------------------------------------------------------------
    libraries.nixexpr = {
      srcs = [ "src/libexpr" ];
      public.headers = [ "src/libexpr/include" ];
      # Meson's implicit '.' include: the generated parser and lexer live in $gen and
      # quote-include parser-scanner-decls.hh / lexer-helpers.hh from the source dir.
      headers = [ "src/libexpr" ];
      public.deps = [
        ":nixutil"
        ":nixstore"
        ":nixfetchers"
        pkgs.nlohmann_json
      ]
      ++ lib.optionals withGC [ pkgs.boehmgc ];
      deps = [
        pkgs.toml11
        pkgs.boost
      ]
      ++ lib.optionals withCpuid [ pkgs.libcpuid ];
      links = [
        "boost_container"
        "boost_context"
      ];
      inherit version;

      generate = {
        # bison and flex, exactly meson's custom_targets; the outputs compile with the
        # library and $gen joins its include path (eval.cc includes "parser-tab.hh").
        parser = {
          command = "bison -v -o $gen/parser-tab.cc src/libexpr/parser.y -d";
          inputs = [ "src/libexpr/parser.y" ];
          outputs = [
            "parser-tab.cc"
            "parser-tab.hh"
          ];
          tools = [ pkgs.bison ];
        };
        lexer = {
          command = "flex -Cf --outfile $gen/lexer-tab.cc --header-file=$gen/lexer-tab.hh src/libexpr/lexer.l";
          inputs = [ "src/libexpr/lexer.l" ];
          outputs = [
            "lexer-tab.cc"
            "lexer-tab.hh"
          ];
          tools = [ pkgs.flex ];
        };
      }
      // embeds [
        "src/libexpr/imported-drv-to-derivation.nix"
        "src/libexpr/fetchurl.nix"
      ]
      // {
        # This one keeps its directory prefix: eval.cc includes
        # "primops/derivation.nix.gen.hh".
        "derivation.nix" = {
          command = ''mkdir -p "$gen/primops" && { echo 'R"__NIX_STR(' && cat src/libexpr/primops/derivation.nix && echo ')__NIX_STR"'; } > "$gen/primops/derivation.nix.gen.hh"'';
          inputs = [ "src/libexpr/primops/derivation.nix" ];
          outputs = [ "primops/derivation.nix.gen.hh" ];
        };
      };

      configHeaders."nix/expr/config.hh" = {
        public = true;
        values = {
          NIX_USE_BOEHMGC = withGC;
          GC_NO_INLINE_STD_NEW = false;
        };
      };
      configHeaders."expr-config-private.hh" = {
        values.HAVE_LIBCPUID = withCpuid;
        probes = {
          HAVE_SYSCONF.function = "sysconf";
          HAVE_PTHREAD_ATTR_GET_NP.function = "pthread_attr_get_np";
          HAVE_PTHREAD_GETATTR_NP = {
            function = "pthread_getattr_np";
            headers = [ "pthread.h" ];
          };
          HAVE_TOML11_4.compiles = ''
            #include <toml.hpp>
            #if !defined(TOML11_VERSION_MAJOR) || TOML11_VERSION_MAJOR < 4
            #error "toml11 is older than 4"
            #endif
            int main(void) { return 0; }
          '';
        };
      };
    };

    # ---- nix-flake ------------------------------------------------------------------
    libraries.nixflake = {
      srcs = [ "src/libflake" ];
      public.headers = [ "src/libflake/include" ];
      public.deps = [
        ":nixutil"
        ":nixstore"
        ":nixfetchers"
        ":nixexpr"
      ];
      deps = [ pkgs.nlohmann_json ];
      inherit version;

      generate = embeds [ "src/libflake/call-flake.nix" ];
    };

    # ---- nix-main -------------------------------------------------------------------
    libraries.nixmain = {
      srcs = [ "src/libmain" ];
      public.headers = [ "src/libmain/include" ];
      # nix-expr rides along for the NIX_USE_BOEHMGC macro alone, meson's own comment.
      public.deps = [
        ":nixutil"
        ":nixstore"
        ":nixexpr"
      ];
      inherit version;

      configHeaders."main-config-private.hh".probes.HAVE_PUBSETBUF.compiles = ''
        #include <iostream>
        using namespace std;
        static char buf[1024];
        int main(void) { cerr.rdbuf()->pubsetbuf(buf, sizeof(buf)); return 0; }
      '';
    };

    # ---- nix-cmd --------------------------------------------------------------------
    libraries.nixcmd = {
      srcs = [ "src/libcmd" ];
      public.headers = [ "src/libcmd/include" ];
      public.deps = [
        ":nixutil"
        ":nixstore"
        ":nixfetchers"
        ":nixexpr"
        ":nixflake"
        ":nixmain"
      ];
      deps = [
        pkgs.editline
        pkgs.nlohmann_json
      ]
      ++ lib.optionals withMarkdown [ pkgs.lowdown ];
      inherit version;

      configHeaders."cmd-config-private.hh".values = {
        HAVE_LOWDOWN = withMarkdown;
        HAVE_LOWDOWN_1_4 = withMarkdown;
        HAVE_LOWDOWN_3 = withMarkdown;
        USE_READLINE = false;
      };
    };

    # ---- the nix CLI ----------------------------------------------------------------
    binaries.nix = {
      srcs = [ "src/nix" ];
      headers = [ "src/nix" ];
      deps = [
        ":nixcmd"
        ":nixflake"
        ":nixexpr"
        ":nixfetchers"
        ":nixmain"
        ":nixstore"
        ":nixutil"
        pkgs.nlohmann_json
        pkgs.editline
        pkgs.boost
      ];
      links = [ "boost_container" ];

      generate = embeds [
        "doc/manual/generate-manpage.nix"
        "doc/manual/generate-settings.nix"
        "doc/manual/generate-store-info.nix"
        "doc/manual/utils.nix"
        "src/nix/get-env.sh"
        # profiles.md in src/nix is a symlink here; embed the real file so the pruned
        # tree carries the bytes, not a dangling link.
        "doc/manual/source/command-ref/files/profiles.md"
        "src/nix/nix-channel/unpack-channel.nix"
        "src/nix/nix-env/buildenv.nix"
      ]
      // {
        # Also a symlink, whose include name differs from its real basename.
        "help-stores.md" = embedAs "help-stores.md" "doc/manual/source/store/types/index.md.in";
      };

      configHeaders."cli-config-private.hh".values = {
        NIX_CLI_VERSION = version;
        NIX_BIN_DIR = "${placeholder "out"}/bin";
        NIX_MAN_DIR = "${placeholder "out"}/share/man";
      };

      # The classic CLI, eleven names on one binary — meson's install_symlink list.
      aliases = [
        "nix-build"
        "nix-channel"
        "nix-collect-garbage"
        "nix-copy-closure"
        "nix-daemon"
        "nix-env"
        "nix-hash"
        "nix-instantiate"
        "nix-prefetch-url"
        "nix-shell"
        "nix-store"
      ];
    };
  };
}
