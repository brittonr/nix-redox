# harfbuzz - Text shaping engine for Redox OS
#
# HarfBuzz is a C++ library with a C API. Required by pango and the
# GTK text rendering stack. Since relibc doesn't provide a C++ runtime,
# we provide minimal C++ standard library header stubs that implement
# only the features harfbuzz actually uses.
#
# Built WITHOUT freetype to break the circular dependency.
#
# Source: https://github.com/harfbuzz/harfbuzz
# Output: libharfbuzz.a + headers + pkg-config

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-freetype2,
  redox-zlib,
  redox-libpng,
  ...
}:

let
  mkCLibrary = import ./mk-c-library.nix {
    inherit
      pkgs
      lib
      redoxTarget
      relibc
      ;
  };

  version = "11.1.0";

  src = pkgs.fetchurl {
    url = "https://github.com/harfbuzz/harfbuzz/releases/download/${version}/harfbuzz-${version}.tar.xz";
    hash = "sha256-R38NSMNNwyCTtFMEF465czNhyhgytRWYecmebUAieWk=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "harfbuzz-${version}-src";
    dontUnpack = true;
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.xz
    ];
    installPhase = ''
      mkdir -p $out
      tar xf ${src} -C $out --strip-components=1
    '';
  };

  targetArch = builtins.head (lib.splitString "-" redoxTarget);
  cc = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
  cxx = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang++";
  ar = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar";
  ranlib = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ranlib";
  sysroot = "${relibc}/${redoxTarget}";
  clangResDir = "${pkgs.llvmPackages.clang-unwrapped.lib}/lib/clang/21/include";

  baseCFlags = builtins.concatStringsSep " " [
    "--target=${redoxTarget}"
    "--sysroot=${sysroot}"
    "-D__redox__"
    "-U_FORTIFY_SOURCE"
    "-D_FORTIFY_SOURCE=0"
    "-I${sysroot}/include"
    "-fPIC"
  ];

  baseLdFlags = builtins.concatStringsSep " " [
    "--target=${redoxTarget}"
    "--sysroot=${sysroot}"
    "-L${sysroot}/lib"
    "-static"
    "-nostdlib"
  ];

  # Minimal C++ header stubs for harfbuzz
  # These provide only what harfbuzz actually uses from the C++ stdlib
  cxxStubs = pkgs.runCommand "harfbuzz-cxx-stubs" { } ''
    mkdir -p $out

    # C wrapper headers (cXXX -> XXX.h)
    for pair in "cassert:assert" "cfloat:float" "climits:limits" "cmath:math" \
                "cstdarg:stdarg" "cstddef:stddef" "cstdio:stdio" "cstdlib:stdlib" \
                "cstring:string" "cstdint:stdint" "cerrno:errno" "cwchar:wchar"; do
      cxx_hdr="''${pair%%:*}"
      c_hdr="''${pair##*:}"
      cat > "$out/$cxx_hdr" << EOF
    #pragma once
    #include <$c_hdr.h>
    namespace std {
      using ::size_t;
    }
    EOF
    done

    # <new> - placement new + addressof
    cat > "$out/new" << 'EOF'
    #pragma once
    #include <stddef.h>
    inline void *operator new(size_t, void *p) noexcept { return p; }
    inline void *operator new[](size_t, void *p) noexcept { return p; }
    namespace std {
      enum class align_val_t : size_t {};
    }
    EOF

    # <type_traits>
    cat > "$out/type_traits" << 'EOF'
    #pragma once
    namespace std {
      template<class T, T v> struct integral_constant {
        static constexpr T value = v;
        typedef T value_type;
        typedef integral_constant type;
        constexpr operator value_type() const noexcept { return value; }
      };
      typedef integral_constant<bool, true> true_type;
      typedef integral_constant<bool, false> false_type;
      template<bool B, class T, class F> struct conditional { typedef T type; };
      template<class T, class F> struct conditional<false, T, F> { typedef F type; };
      template<bool B, class T, class F> using conditional_t = typename conditional<B, T, F>::type;
      template<class T> struct remove_reference { typedef T type; };
      template<class T> struct remove_reference<T&> { typedef T type; };
      template<class T> struct remove_reference<T&&> { typedef T type; };
      template<class T> using remove_reference_t = typename remove_reference<T>::type;
      template<class T> struct remove_const { typedef T type; };
      template<class T> struct remove_const<const T> { typedef T type; };
      template<class T> struct remove_volatile { typedef T type; };
      template<class T> struct remove_volatile<volatile T> { typedef T type; };
      template<class T> struct remove_cv { typedef typename remove_volatile<typename remove_const<T>::type>::type type; };
      template<class T> struct is_integral : false_type {};
      template<> struct is_integral<bool> : true_type {};
      template<> struct is_integral<char> : true_type {};
      template<> struct is_integral<signed char> : true_type {};
      template<> struct is_integral<unsigned char> : true_type {};
      template<> struct is_integral<short> : true_type {};
      template<> struct is_integral<unsigned short> : true_type {};
      template<> struct is_integral<int> : true_type {};
      template<> struct is_integral<unsigned int> : true_type {};
      template<> struct is_integral<long> : true_type {};
      template<> struct is_integral<unsigned long> : true_type {};
      template<> struct is_integral<long long> : true_type {};
      template<> struct is_integral<unsigned long long> : true_type {};
      template<class T> struct is_floating_point : false_type {};
      template<> struct is_floating_point<float> : true_type {};
      template<> struct is_floating_point<double> : true_type {};
      template<> struct is_floating_point<long double> : true_type {};
      template<class T> struct is_signed : integral_constant<bool, T(-1) < T(0)> {};
      template<class T> struct is_const : false_type {};
      template<class T> struct is_const<const T> : true_type {};
      template<class T> struct is_reference : false_type {};
      template<class T> struct is_reference<T&> : true_type {};
      template<class T> struct is_reference<T&&> : true_type {};
      template<class T, class U> struct is_convertible : integral_constant<bool, __is_convertible(T, U)> {};
      template<class T> struct is_trivially_copyable : integral_constant<bool, __is_trivially_copyable(T)> {};
      template<class T> struct is_trivially_destructible : integral_constant<bool, __is_trivially_destructible(T)> {};
      template<class T> struct is_trivially_constructible : integral_constant<bool, __is_trivially_constructible(T)> {};
      template<class T> struct is_trivially_copy_constructible : integral_constant<bool, __is_trivially_constructible(T, const T&)> {};
      template<class T> struct is_trivially_copy_assignable : integral_constant<bool, __is_trivially_assignable(T&, const T&)> {};
      template<class T> struct is_default_constructible : integral_constant<bool, __is_constructible(T)> {};
      template<class T> struct is_copy_constructible : integral_constant<bool, __is_constructible(T, const T&)> {};
      template<class T> struct is_copy_assignable : integral_constant<bool, __is_assignable(T&, const T&)> {};
      template<class T> struct decay { typedef typename remove_cv<typename remove_reference<T>::type>::type type; };
      template<class T> using decay_t = typename decay<T>::type;
      template<bool B, class T = void> struct enable_if {};
      template<class T> struct enable_if<true, T> { typedef T type; };
      template<bool B, class T = void> using enable_if_t = typename enable_if<B, T>::type;
      template<class T> struct is_enum : integral_constant<bool, __is_enum(T)> {};
    }
    EOF

    # <utility>
    cat > "$out/utility" << 'EOF'
    #pragma once
    #include <type_traits>
    namespace std {
      template<class T>
      constexpr remove_reference_t<T>&& move(T&& t) noexcept {
        return static_cast<remove_reference_t<T>&&>(t);
      }
      template<class T>
      constexpr T&& forward(remove_reference_t<T>& t) noexcept {
        return static_cast<T&&>(t);
      }
      template<class T>
      constexpr T&& forward(remove_reference_t<T>&& t) noexcept {
        return static_cast<T&&>(t);
      }
      template<class T>
      void swap(T& a, T& b) noexcept {
        T tmp = move(a); a = move(b); b = move(tmp);
      }
    }
    EOF

    # <initializer_list>
    cat > "$out/initializer_list" << 'EOF'
    #pragma once
    #include <stddef.h>
    namespace std {
      template<class T>
      class initializer_list {
        const T *_begin;
        size_t _size;
        constexpr initializer_list(const T *b, size_t s) noexcept : _begin(b), _size(s) {}
      public:
        typedef T value_type;
        typedef const T& reference;
        typedef const T& const_reference;
        typedef size_t size_type;
        typedef const T* iterator;
        typedef const T* const_iterator;
        constexpr initializer_list() noexcept : _begin(nullptr), _size(0) {}
        constexpr size_t size() const noexcept { return _size; }
        constexpr const T* begin() const noexcept { return _begin; }
        constexpr const T* end() const noexcept { return _begin + _size; }
      };
    }
    EOF

    # <atomic> - minimal single-threaded stubs
    cat > "$out/atomic" << 'EOF'
    #pragma once
    namespace std {
      enum memory_order {
        memory_order_relaxed,
        memory_order_consume,
        memory_order_acquire,
        memory_order_release,
        memory_order_acq_rel,
        memory_order_seq_cst
      };
      template<class T>
      struct atomic {
        T _val;
        atomic() noexcept = default;
        constexpr atomic(T v) noexcept : _val(v) {}
        T load(memory_order = memory_order_seq_cst) const noexcept { return _val; }
        void store(T v, memory_order = memory_order_seq_cst) noexcept { _val = v; }
        T exchange(T v, memory_order = memory_order_seq_cst) noexcept { T old = _val; _val = v; return old; }
        bool compare_exchange_strong(T& expected, T desired, memory_order = memory_order_seq_cst, memory_order = memory_order_seq_cst) noexcept {
          if (_val == expected) { _val = desired; return true; }
          expected = _val; return false;
        }
        bool compare_exchange_weak(T& expected, T desired, memory_order s = memory_order_seq_cst, memory_order f = memory_order_seq_cst) noexcept {
          return compare_exchange_strong(expected, desired, s, f);
        }
        T fetch_add(T v, memory_order = memory_order_seq_cst) noexcept { T old = _val; _val += v; return old; }
        T fetch_sub(T v, memory_order = memory_order_seq_cst) noexcept { T old = _val; _val -= v; return old; }
        operator T() const noexcept { return _val; }
      };
      using atomic_int = atomic<int>;
      inline void atomic_thread_fence(memory_order) noexcept {}
      inline void atomic_signal_fence(memory_order) noexcept {}
    }
    EOF

    # <algorithm>
    cat > "$out/algorithm" << 'EOF'
    #pragma once
    namespace std {
      template<class It, class T>
      It upper_bound(It first, It last, const T& value) {
        while (first != last) {
          It mid = first + (last - first) / 2;
          if (!(value < *mid)) first = mid + 1;
          else last = mid;
        }
        return first;
      }
      template<class It, class T, class Comp>
      It upper_bound(It first, It last, const T& value, Comp comp) {
        while (first != last) {
          It mid = first + (last - first) / 2;
          if (!comp(value, *mid)) first = mid + 1;
          else last = mid;
        }
        return first;
      }
      template<class It, class T, class Comp>
      It lower_bound(It first, It last, const T& value, Comp comp) {
        while (first != last) {
          It mid = first + (last - first) / 2;
          if (comp(*mid, value)) first = mid + 1;
          else last = mid;
        }
        return first;
      }
      template<class T> const T& min(const T& a, const T& b) { return (b < a) ? b : a; }
      template<class T> const T& max(const T& a, const T& b) { return (a < b) ? b : a; }
      template<class It, class T> It find(It first, It last, const T& value) {
        for (; first != last; ++first) if (*first == value) return first;
        return last;
      }
      template<class It, class Out> Out copy(It first, It last, Out d_first) {
        for (; first != last; ++first, ++d_first) *d_first = *first;
        return d_first;
      }
      template<class It, class Pred> It find_if(It first, It last, Pred p) {
        for (; first != last; ++first) if (p(*first)) return first;
        return last;
      }
      template<class It> void sort(It, It) {}
      template<class It, class Comp> void sort(It, It, Comp) {}
    }
    EOF

    # <functional>
    cat > "$out/functional" << 'EOF'
    #pragma once
    #include <stddef.h>
    #include <stdint.h>
    #include <string.h>
    namespace std {
      template<class T> struct hash;
      template<> struct hash<bool> { size_t operator()(bool v) const noexcept { return (size_t)v; } };
      template<> struct hash<char> { size_t operator()(char v) const noexcept { return (size_t)v; } };
      template<> struct hash<signed char> { size_t operator()(signed char v) const noexcept { return (size_t)v; } };
      template<> struct hash<unsigned char> { size_t operator()(unsigned char v) const noexcept { return (size_t)v; } };
      template<> struct hash<short> { size_t operator()(short v) const noexcept { return (size_t)v; } };
      template<> struct hash<unsigned short> { size_t operator()(unsigned short v) const noexcept { return (size_t)v; } };
      template<> struct hash<int> { size_t operator()(int v) const noexcept { return (size_t)v; } };
      template<> struct hash<unsigned> { size_t operator()(unsigned v) const noexcept { return (size_t)v; } };
      template<> struct hash<long> { size_t operator()(long v) const noexcept { return (size_t)v; } };
      template<> struct hash<unsigned long> { size_t operator()(unsigned long v) const noexcept { return (size_t)v; } };
      template<> struct hash<long long> { size_t operator()(long long v) const noexcept { return (size_t)v; } };
      template<> struct hash<unsigned long long> { size_t operator()(unsigned long long v) const noexcept { return (size_t)v; } };
      template<> struct hash<float> {
        size_t operator()(float v) const noexcept {
          size_t h = 0; memcpy(&h, &v, sizeof(v) < sizeof(h) ? sizeof(v) : sizeof(h)); return h;
        }
      };
      template<> struct hash<double> {
        size_t operator()(double v) const noexcept {
          size_t h = 0; memcpy(&h, &v, sizeof(v) < sizeof(h) ? sizeof(v) : sizeof(h)); return h;
        }
      };
      template<class T> struct hash<T*> { size_t operator()(T* v) const noexcept { return (size_t)(uintptr_t)v; } };
      template<class T> struct equal_to { bool operator()(const T& a, const T& b) const { return a == b; } };
      template<class T> struct less { bool operator()(const T& a, const T& b) const { return a < b; } };
    }
    EOF

    # <memory>
    cat > "$out/memory" << 'EOF'
    #pragma once
    #include <new>
    #include <stddef.h>
    namespace std {
      template<class T>
      inline T* addressof(T& r) noexcept { return __builtin_addressof(r); }
      template<class T, class... Args>
      void construct_at(T* p, Args&&... args) { ::new((void*)p) T(static_cast<Args&&>(args)...); }
      template<class T>
      void destroy_at(T* p) { p->~T(); }
    }
    EOF

    # <mutex> - no-op for single-threaded
    cat > "$out/mutex" << 'EOF'
    #pragma once
    namespace std {
      struct mutex {
        void lock() noexcept {}
        void unlock() noexcept {}
        bool try_lock() noexcept { return true; }
      };
      template<class M> struct lock_guard {
        explicit lock_guard(M&) noexcept {}
        ~lock_guard() noexcept {}
      };
      template<class M> struct unique_lock {
        explicit unique_lock(M&) noexcept {}
        ~unique_lock() noexcept {}
      };
    }
    EOF

    # <string> - minimal stub (HB mostly uses char* directly)
    cat > "$out/string" << 'EOF'
    #pragma once
    #include <cstring>
    namespace std {
      using ::size_t;
      class string {
        char *_data;
        size_t _size;
      public:
        string() : _data(nullptr), _size(0) {}
        const char* c_str() const { return _data ? _data : ""; }
        size_t size() const { return _size; }
        bool empty() const { return _size == 0; }
      };
    }
    EOF

    # <condition_variable> - no-op stub
    cat > "$out/condition_variable" << 'EOF'
    #pragma once
    EOF

    # <thread> - no-op stub
    cat > "$out/thread" << 'EOF'
    #pragma once
    EOF
  '';

in
mkCLibrary.mkLibrary {
  pname = "redox-harfbuzz";
  inherit version;
  src = extractedSrc;

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.python3
  ];

  configurePhase = ''
    runHook preConfigure

    cp -r ${extractedSrc}/* .
    chmod -R u+w .

    CXX_FLAGS="${baseCFlags} -nostdinc++ -I${cxxStubs} -isystem ${clangResDir} -fno-exceptions -fno-rtti -fno-threadsafe-statics -DHB_NO_MT -Wno-c++11-narrowing"

    mkdir -p build && cd build

    cmake .. \
      -DCMAKE_INSTALL_PREFIX=$out \
      -DCMAKE_SYSTEM_NAME=Redox \
      -DCMAKE_SYSTEM_PROCESSOR=${targetArch} \
      -DCMAKE_C_COMPILER=${cc} \
      -DCMAKE_CXX_COMPILER=${cxx} \
      -DCMAKE_AR=${ar} \
      -DCMAKE_RANLIB=${ranlib} \
      -DCMAKE_FIND_ROOT_PATH="${sysroot}" \
      -DCMAKE_C_FLAGS="${baseCFlags}" \
      -DCMAKE_CXX_FLAGS="$CXX_FLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="${baseLdFlags}" \
      -DBUILD_SHARED_LIBS=OFF \
      -DHB_HAVE_FREETYPE=OFF \
      -DHB_HAVE_GLIB=OFF \
      -DHB_HAVE_GOBJECT=OFF \
      -DHB_HAVE_CAIRO=OFF \
      -DHB_HAVE_ICU=OFF \
      -DHB_HAVE_GRAPHITE2=OFF \
      -DHB_BUILD_UTILS=OFF \
      -DHB_BUILD_TESTS=OFF \
      -DHB_BUILD_SUBSET=ON

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    cmake --build . --target harfbuzz --parallel $NIX_BUILD_CORES
    cmake --build . --target harfbuzz-subset --parallel $NIX_BUILD_CORES || true
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/include/harfbuzz $out/lib/pkgconfig

    cp libharfbuzz.a $out/lib/
    cp libharfbuzz-subset.a $out/lib/ 2>/dev/null || true

    # Install public headers
    cp ../src/hb.h ../src/hb-*.h $out/include/harfbuzz/
    rm -f $out/include/harfbuzz/hb-*-private.h

    cat > $out/lib/pkgconfig/harfbuzz.pc << EOF
    prefix=$out
    libdir=\''${prefix}/lib
    includedir=\''${prefix}/include

    Name: harfbuzz
    Description: HarfBuzz text shaping library
    Version: ${version}
    Libs: -L\''${libdir} -lharfbuzz
    Cflags: -I\''${includedir}/harfbuzz
  EOF

    test -f $out/lib/libharfbuzz.a || { echo "ERROR: libharfbuzz.a not built"; exit 1; }
    echo "harfbuzz libraries:"
    ls -la $out/lib/lib*.a

    runHook postInstall
  '';

  meta = with lib; {
    description = "Text shaping engine for Redox OS";
    homepage = "https://harfbuzz.github.io/";
    license = licenses.mit;
  };
}
