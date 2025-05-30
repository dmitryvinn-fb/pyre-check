(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open IntegrationTest

let test_check_protocol =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        def foo(self) -> int: ...

      class Alpha:
        def foo(self) -> int:
          return 9

      def foo(p: P) -> int:
        return p.foo()

      def bar(a: Alpha) -> None:
        foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class Beta: pass
      class Chi(Beta): pass

      class P(typing.Protocol):
        def foo(self) -> Beta: ...

      class Alpha:
        def foo(self) -> Chi:
          return Chi()

      def foo(p: P) -> Beta:
        return p.foo()

      def bar(a: Alpha) -> None:
        foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        def foo(self) -> int: ...

      class Base:
        def foo(self) -> int:
          return 9
      class Child(Base):
        def baz(self) -> int:
          return 8

      def foo(p: P) -> int:
        return p.foo()

      def bar(a: Child) -> None:
        foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class FooProtocol(typing.Protocol):
        def foo(self) -> int: ...

      class FooBarProtocol(FooProtocol, typing.Protocol):
        def bar(self) -> int: ...


      class FooClass():
        def foo(self) -> int:
          return 7
      class FooBarClass():
        def foo(self) -> int:
          return 7
        def bar(self) -> int:
          return 7
      def takesFooBarProtocol(x: FooBarProtocol) -> None: pass

      def f() -> None:
        takesFooBarProtocol(FooClass())
        takesFooBarProtocol(FooBarClass())
    |}
           [
             "Incompatible parameter type [6]: In call `takesFooBarProtocol`, for 1st positional \
              argument, expected `FooBarProtocol` but got `FooClass`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class ParentFoo():
        def foo(self) -> int:
          return 7
      class ParentBar():
        def bar(self) -> int:
          return 9
      class Child(ParentFoo, ParentBar):
        def other(self) -> int:
          return 11
      class FooBarProtocol(typing.Protocol):
        def foo(self) -> int: ...
        def bar(self) -> int: ...
      def takesFooBar(x: FooBarProtocol) -> int:
        return x.bar() + x.foo()
      def fun() -> int:
        return takesFooBar(Child())
    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        def foo(self) -> int: ...

      class ProtocolBase(typing.Protocol):
        def foo(self) -> int:
          return 9
      class Child(ProtocolBase):
        def baz(self) -> int:
          return 8

      def foo(p: P) -> int:
        return p.foo()

      def bar(a: Child) -> None:
        foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class FooProtocol(typing.Protocol):
        def foo(self) -> int: ...
      class FooBarProtocol(typing.Protocol):
        def foo(self) -> int: ...
        def bar(self) -> int: ...
      def takesFoo(x: FooProtocol) -> int:
        return x.foo()
      def takesFooBar(x: FooBarProtocol) -> int:
        y = takesFoo(x)
        return x.bar() + y
    |}
           [];
      (* Collection -> Sized is special cased for now *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      def foo(
        a: typing.Sequence[int],
        b: typing.Mapping[int, int],
        c: typing.AbstractSet[int],
        d: typing.Collection[int]
        ) -> int:
        return len(a) + len(b) + len(c) + len(d)
    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      T = typing.TypeVar("T")
      def foo(d: typing.Collection[T]) -> T: ...
      def bar(x: typing.List[int]) -> int:
        reveal_type(foo(x))
        return foo(x)
    |}
           ["Revealed type [-1]: Revealed type for `test.foo(x)` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class Alpha:
        def __hash__(self) -> int:
          return 9

      def foo(p: typing.Hashable) -> int:
        return p.__hash__()

      def bar(a: Alpha) -> None:
        foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        foo: int

      class A:
        foo: int = 7

      def foo(p: P) -> int:
        return p.foo

      def bar(a: A) -> None:
        foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        foo: int

      class A(P):
        pass

    |}
           [
             "Uninitialized attribute [13]: Attribute `foo` inherited from protocol `P` in class \
              `A` to have type `int` but is never initialized.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        foo: int

      class A(P):
        pass

      class B(P):
        foo = 100

    |}
           [
             "Uninitialized attribute [13]: Attribute `foo` inherited from protocol `P` in class \
              `A` to have type `int` but is never initialized.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        foo: int
        def __init__(self) -> None:
          pass
      |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from builtins import A
      import typing
      class P(typing.Protocol):
        def foo(self) -> P: ...

      class Alpha:
        def foo(self) -> A:
          return A()

      def foo(p: P) -> P:
        return p.foo()

      def bar(a: Alpha) -> None:
        foo(a)

    |}
           [
             "Incompatible parameter type [6]: In call `foo`, for 1st positional argument, \
              expected `P` but got `Alpha`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P1(typing.Protocol):
        def foo(self) -> P2: ...
      class P2(typing.Protocol):
        def foo(self) -> P1: ...

      class Alpha:
        def foo(self) -> Beta:
          return Beta()
      class Beta:
        def foo(self) -> Alpha:
          return Alpha()

      def foo(p: P1) -> P2:
        return p.foo()

      def bar(a: Alpha) -> None:
        foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        def foo(self, param: int) -> int: ...

      class Alpha:
        def foo(self, mismatch: int) -> int:
          return 9

      def foo(p: P) -> int:
        return p.foo(1)

      def bar(a: Alpha) -> None:
        foo(a)

    |}
           [
             "Incompatible parameter type [6]: In call `foo`, for 1st positional argument, \
              expected `P` but got `Alpha`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        def foo(self, __dunder: int) -> int: ...

      class Alpha:
        def foo(self, x: int) -> int:
          return 9

      class Beta:
        def foo(self, y: int) -> int:
          return 9

      def foo(p: P) -> int:
        return p.foo(1)

      def bar(a: Alpha, b: Beta) -> None:
        foo(a)
        foo(b)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_default_type_errors
           {|
      import typing
      class P(typing.Protocol):
        def foo(self) -> int: ...

      class Alpha:
        def foo(self) -> typing.Any:
          return 9

      def foo(p: P) -> int:
        return p.foo()

      def bar(a: Alpha) -> None:
        foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        pass
      P()
    |}
           ["Invalid class instantiation [45]: Cannot instantiate protocol `P`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        def foo(self) -> int: ...
      class AlphaMeta(type):
        def foo(self) -> int: ...
      class Alpha(metaclass=AlphaMeta):
        pass
      def foo(x: P) -> None:
        pass
      def bar() -> None:
        # should fail
        foo(Alpha())
        # should be allowed
        foo(Alpha)
    |}
           [
             "Incompatible parameter type [6]: In call `foo`, for 1st positional argument, \
              expected `P` but got `Alpha`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from enum import Enum
    from typing import Iterable, TypeVar
    T = TypeVar("T")

    class AlphaEnum(Enum):
        x = 'x'
        y = 'y'

    def foo(x: Iterable[T]) -> T :...

    def bar() -> None:
      x = foo(AlphaEnum)
      reveal_type(x)
    |}
           ["Revealed type [-1]: Revealed type for `x` is `AlphaEnum`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    from typing import Protocol, TypeVar, Union
    class Alpha:
      x: int = 9

    class Beta:
      x: str = "A"

    T = TypeVar("T", covariant=True)
    class P(Protocol[T]):
      x: T

    def foo(x: P[T]) -> T :
      return x.x

    def bar(a: Alpha, b: Beta, u: Union[Alpha, Beta]) -> None:
      x = foo(a)
      reveal_type(x)
      y = foo(b)
      reveal_type(y)
      z = foo(u)
      reveal_type(z)
    |}
           [
             "Revealed type [-1]: Revealed type for `x` is `int`.";
             "Revealed type [-1]: Revealed type for `y` is `str`.";
             "Revealed type [-1]: Revealed type for `z` is `Union[int, str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        __foo: int
        def __bar(self) -> int: ...
    |}
           [
             "Private protocol property [52]: Protocol `P` has private property `__bar`.";
             "Private protocol property [52]: Protocol `P` has private property `__foo`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import Protocol, Type, TypeVar

      T = TypeVar("T")

      class P(Protocol):
          @classmethod
          def cm(cls: Type[T], x: int) -> T: ...

      class I:
          @classmethod
          def cm(cls: Type[T], x: int) -> T: ...

      x: P = I()
    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import Protocol, Type, TypeVar

      class P(Protocol):
          @classmethod
          def cm(cls, x: int) -> str: ...

      class I:
          @classmethod
          def cm(cls, x: int) -> str: ...

      # this is technically unsound since P().cm.__func__ =/= I().cm.__func__
      x: P = I()
    |}
           [];
    ]


let test_check_generic_protocols =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      T = typing.TypeVar("T", int, str)
      class P(typing.Protocol[T]):
        def foo(self) -> T: ...

      class Alpha():
        def foo(self) -> int:
          return 7

      def foo(p: P[int]) -> int:
        return p.foo()

      def bar(a: Alpha) -> None:
        foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      T = typing.TypeVar("T", int, str)
      class P(typing.Protocol[T]):
        def foo(self) -> T: ...

      class Alpha():
        def foo(self) -> int:
          return 7

      def foo(p: P[str]) -> str:
        return p.foo()

      def bar(a: Alpha) -> None:
        foo(a)

    |}
           [
             "Incompatible parameter type [6]: In call `foo`, for 1st positional argument, \
              expected `P[str]` but got `Alpha`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      T = typing.TypeVar("T", int, str)
      class P(typing.Protocol[T]):
        def foo(self) -> T: ...

      class Alpha():
        def foo(self) -> int:
          return 7

      T2 = typing.TypeVar("T2", int, str)
      def foo(p: P[T2]) -> T2:
        return p.foo()

      def bar(a: Alpha) -> int:
        v = foo(a)
        reveal_type(v)
        return v

    |}
           ["Revealed type [-1]: Revealed type for `v` is `int`."];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      T = typing.TypeVar("T", int, str)
      class P(typing.Protocol[T]):
        def foo(self) -> T: ...

      class Alpha():
        def foo(self) -> bool:
          return True

      T2 = typing.TypeVar("T2", int, str)
      def foo(p: P[T2]) -> T2:
        return p.foo()

      def bar(a: Alpha) -> None:
        foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      X = typing.TypeVar("X")
      Y = typing.TypeVar("Y")
      class PXY(typing.Protocol[X, Y]):
        x: X
        y: Y

      class PYX(typing.Protocol[Y, X]):
        x: X
        y: Y

      class Foo:
        x: int = 1
        y: str = "A"

      def xy(x: PXY[X, Y]) -> PXY[X, Y]: ...
      def yx(x: PYX[X, Y]) -> PYX[X, Y]: ...

      def bar(f: Foo) -> None:
        a = xy(f)
        reveal_type(a)
        b = yx(f)
        reveal_type(b)
    |}
           [
             "Revealed type [-1]: Revealed type for `a` is `PXY[int, str]`.";
             "Revealed type [-1]: Revealed type for `b` is `PYX[str, int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import Any, Generic, overload, Protocol, TypeVar

      _T_contra = TypeVar("_T_contra", contravariant=True)
      AnyStr = TypeVar("AnyStr", str, bytes)

      class SupportsWrite(Protocol[_T_contra]):
          def write(self, s: _T_contra, /) -> object:
              pass

      class IO(Generic[AnyStr]):
          @overload
          def write(self: "IO[bytes]", s: bytes, /) -> int: ...

          @overload
          def write(self, s: AnyStr, /) -> int: ...

          # pyre-ignore[2]: Explicit Any.
          def write(self: Any, s: Any, /) -> int:
              return 0

      def f(x: SupportsWrite[str]) -> None:
          pass

      def g(x: IO[str]) -> None:
          f(x)
             |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import Iterable, Protocol, TypeVar

      _T = TypeVar('_T')

      class HasKeys(Protocol[_T]):
          def keys(self) -> Iterable[_T]: ...

      def f(x: HasKeys[str]) -> None:
        pass

      def g() -> None:
        f({})
      |}
           [];
    ]


let test_check_generic_implementors =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      def foo(l: typing.List[int]) -> int:
         return len(l)
    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        def foo(self) -> typing.Union[int, str]: ...

      T = typing.TypeVar("T", bound=typing.Union[int, str])
      class Alpha(typing.Generic[T]):
        x: T
        def __init__(self, x: T) -> None:
          self.x = x
        def foo(self) -> T:
          return self.x

      def foo(p: P) -> typing.Union[int, str]:
        return p.foo()

      def bar(a: Alpha[int]) -> None:
        foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    T1 = typing.TypeVar("T1")
    class P(typing.Protocol[T1]):
      def foo(self) -> T1: ...

    T = typing.TypeVar("T", bound=typing.Union[int, str])
    class Alpha(typing.Generic[T]):
      x: T
      def __init__(self, x: T) -> None:
        self.x = x
      def foo(self) -> T:
        return self.x

    def foo(p: P[int]) -> int:
      return p.foo()

    def bar(a: Alpha[int]) -> None:
      foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    T1 = typing.TypeVar("T1")
    class P(typing.Protocol[T1]):
      def foo(self) -> T1: ...

    T = typing.TypeVar("T", bound=typing.Union[int, str])
    class Alpha(typing.Generic[T]):
      x: T
      def __init__(self, x: T) -> None:
        self.x = x
      def foo(self) -> T:
        return self.x

    def foo(p: P[bool]) -> bool:
      return p.foo()

    def bar(a: Alpha[int]) -> None:
      foo(a)

    |}
           [
             "Incompatible parameter type [6]: In call `foo`, for 1st positional argument, \
              expected `P[bool]` but got `Alpha[int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
    import typing
    T1 = typing.TypeVar("T1")
    class P(typing.Protocol[T1]):
      def foo(self) -> T1: ...

    T = typing.TypeVar("T", bound=typing.Union[int, str])
    class Alpha(typing.Generic[T]):
      x: T
      def __init__(self, x: T) -> None:
        self.x = x
      def foo(self) -> T:
        return self.x

    T3 = typing.TypeVar("T", bound=typing.Union[int, str])
    def foo(p: P[T3]) -> T3:
      return p.foo()

    def bar(a: Alpha[int]) -> int:
      return foo(a)

    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        def foo(self) -> int: ...

      T = typing.TypeVar("T")
      class Alpha(typing.Generic[T]):
        x: T
        def __init__(self, x: T) -> None:
          self.x = x
        def foo(self) -> T:
          return self.x

      def foo(p: P) -> int:
        return p.foo()

      def bar(a: Alpha[int]) -> None:
        foo(a)

    |}
           [];
    ]


let test_callback_protocols =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        def __call__(self, x: int, y:str) -> bool: ...
      def takesP(f: P) -> bool:
        return f(x = 1, y = "one")
      def exactMatch(x: int, y: str) -> bool:
        return True
      def doesNotMatch(x: int, y: str) -> str:
        return "True"
      def foo() -> None:
        takesP(exactMatch)
        takesP(doesNotMatch)
    |}
           [
             "Incompatible parameter type [6]: In call `takesP`, for 1st positional argument, \
              expected `P` but got `typing.Callable(doesNotMatch)[[Named(x, int), Named(y, str)], \
              str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      class NotAProtocol():
        def __call__(self, x: int, y:str) -> bool: ...
      def exactMatch(x: int, y: str) -> bool:
        return True
      def foo() -> NotAProtocol:
        return exactMatch
    |}
           [
             "Incompatible return type [7]: Expected `NotAProtocol` but got "
             ^ "`typing.Callable(exactMatch)[[Named(x, int), Named(y, str)], bool]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      T = typing.TypeVar("T")
      class P(typing.Protocol[T]):
        def __call__(self, x: int, y:str) -> T: ...
      def takesPInt(f: P[int]) -> int:
        return f(x = 1, y = "one")
      def exactMatch(x: int, y: str) -> int:
        return 7
      def doesNotMatch(x: int, y: str) -> str:
        return "True"
      def foo() -> None:
        takesPInt(exactMatch)
        takesPInt(doesNotMatch)
    |}
           [
             "Incompatible parameter type [6]: In call `takesPInt`, for 1st positional argument, \
              expected `P[int]` but got `typing.Callable(doesNotMatch)[[Named(x, int), Named(y, \
              str)], str]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      T = typing.TypeVar("T")
      class P(typing.Protocol[T]):
        def __call__(self, x: int, y:str) -> T: ...
      T2 = typing.TypeVar("T")
      def takesPGeneric(f: P[T2]) -> T2:
        return f(x = 1, y = "one")
      def intMatch(x: int, y: str) -> int:
        return 7
      def strMatch(x: int, y: str) -> str:
        return "True"
      def doesNotMatch(x: str, y: int) -> int:
        return 17
      def foo() -> None:
        v = takesPGeneric(intMatch)
        reveal_type(v)
        v = takesPGeneric(strMatch)
        reveal_type(v)
        takesPGeneric(doesNotMatch)
    |}
           [
             "Revealed type [-1]: Revealed type for `v` is `int`.";
             "Revealed type [-1]: Revealed type for `v` is `str`.";
             "Incompatible parameter type [6]: In call `takesPGeneric`, for 1st positional \
              argument, expected `P[Variable[T2]]` but got \
              `typing.Callable(doesNotMatch)[[Named(x, str), Named(y, int)], int]`.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      import typing
      class P(typing.Protocol):
        def __call__(self, __dunder: int) -> bool: ...
      def parameterMismatch(x: int) -> bool:
        return True
      def takesP(f: P) -> bool:
        return f(1)
      def foo() -> None:
        takesP(parameterMismatch)
    |}
           [];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import Protocol

      class ShouldMatch(Protocol):
          def __call__(self, p: int) -> H: ...

      class ShouldNotMatch(Protocol):
          def __call__(self, p: str) -> H: ...

      class H:
          def __init__(self, p: int) -> None: ...

      x: ShouldMatch = H
      y: ShouldNotMatch = H
    |}
           [
             "Incompatible variable type [9]: y is declared to have type `ShouldNotMatch` but is \
              used as type `Type[H]`.";
           ];
      (* We should be able to pass a named callable type to a callable protocol that is generic in
         the callable type.

         This example is adapted from
         https://github.com/pytest-dev/pytest/blob/5.4.x/src/_pytest/outcomes.py#L91-L158. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import Any, TypeVar, Callable, Type, Protocol, Optional, NoReturn, cast

      class Exit(BaseException): pass

      _F = TypeVar("_F", bound=Callable[..., object])
      _ET = TypeVar("_ET", bound="Type[BaseException]")


      class _WithException(Protocol[_F, _ET]):
          Exception: _ET
          __call__: _F


      def _with_exception(exception_type: _ET) -> Callable[[_F], _WithException[_F, _ET]]: ...

      @_with_exception(Exit)
      def my_exit(msg: str, returncode: Optional[int] = None) -> "NoReturn": ...

      reveal_type(my_exit)
      my_exit(1)
    |}
           [
             "Invalid type variable [34]: The type variable `Variable[_F (bound to \
              typing.Callable[..., object])]` isn't present in the function's parameters.";
             "Revealed type [-1]: Revealed type for `test.my_exit` is \
              `_WithException[typing.Callable(my_exit)[[Named(msg, str), Named(returncode, \
              Optional[int], default)], NoReturn], Type[Exit]]`.";
             "Incompatible parameter type [6]: In call `my_exit`, for 1st positional argument, \
              expected `str` but got `int`.";
           ];
    ]


let test_hash_protocol =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
      from typing import Hashable

      def foo(h: Hashable) -> int:
        return hash(h)

      foo(None)
    |}
           [];
    ]


let test_protocol_inheritance =
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Protocol

              class Foo: ...
              class Bar(Protocol, Foo): ...
           |}
           [
             "Invalid inheritance [39]: If Protocol is included as a base class, all other base \
              classes must be protocols or Generic.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Protocol, TypeVar

              T = TypeVar("T")
              class Foo: ...
              class Bar(Protocol[T], Foo): ...
           |}
           [
             "Invalid inheritance [39]: If Protocol is included as a base class, all other base \
              classes must be protocols or Generic.";
           ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_type_errors
           {|
              from typing import Generic, Protocol, TypeVar

              T = TypeVar("T")
              class Bar(Protocol, Generic[T]): ...
           |}
           [];
    ]


(* This example demonstrates that the naive recursive type algorithm can be very slow when applied
   to nested container types (e.g. here we are checking whether `list[X]` is a protocol where `X`
   may itself be a list). This is relevant because numpy relies heavily on an `ArrayLike` protocol
   that hits this problem. *)
let test_arraylike_example =
  __FUNCTION__
  >:: fun context ->
  let timer = Timer.start () in
  assert_type_errors
    {|
      from typing import Any, Generic, Iterator, overload, Protocol, TypeVar, Union

      T = TypeVar("T")
      _T_co = TypeVar("_T_co", covariant=True)

      class dtype(Generic[_T_co]):
          pass

      class _SupportsArray(Protocol[_T_co]):
          def __array__(self) -> None: ...

      class _NestedSequence(Protocol[_T_co]):
          @overload
          def __getitem__(self, index: int, /) -> _T_co | _NestedSequence[_T_co]: ...
          @overload
          def __getitem__(self, index: slice, /) -> _NestedSequence[_T_co]: ...
          def __getitem__(self, index: object, /) -> object: ...
          def __iter__(self, /) -> Iterator[_T_co | _NestedSequence[_T_co]]: ...
          def __reversed__(self, /) -> Iterator[_T_co | _NestedSequence[_T_co]]: ...

      _ArrayLike = Union[
          _SupportsArray["dtype[T]"],
          _NestedSequence[_SupportsArray["dtype[T]"]],
      ]

      def array(x: _ArrayLike[T]) -> None: ...

      def test(x: list[list[list[list[list[list[list[list[int]]]]]]]]) -> None:
          array(x)
    |}
    [
      "Incompatible parameter type [6]: In call `array`, for 1st positional argument, expected \
       `Union[_NestedSequence[_SupportsArray[dtype[Variable[T]]]], \
       _SupportsArray[dtype[Variable[T]]]]` but got \
       `List[List[List[List[List[List[List[List[int]]]]]]]]`.";
    ]
    context;
  let time = Timer.stop_in_sec timer in
  let dump_time = false in
  if dump_time then Log.dump "Analysis in `test_arraylike_example` took %f seconds" time;
  ()


let () =
  "protocol"
  >::: [
         test_check_protocol;
         test_check_generic_implementors;
         test_check_generic_protocols;
         test_callback_protocols;
         test_hash_protocol;
         test_protocol_inheritance;
         test_arraylike_example;
       ]
  |> Test.run
