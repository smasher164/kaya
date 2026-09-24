"""The formatter door (docs/compliance-plan.md §1.4, §2.3): dates, times,
numbers, percentages and money written the way the user's platform writes
them, by the platform's own formatter. Pure functions, any thread, no
transaction; `kaya.fmt.date(d, length="medium")`."""

from __future__ import annotations

import dataclasses
import datetime
from typing import Literal

from . import runtime, wire

#: How much of a date or time to write: the numeric form, the abbreviated
#: words, the full words.
Length = Literal["short", "medium", "long"]

_LENGTHS: dict[str, int] = {"short": 0, "medium": 1, "long": 2}


def _errors() -> tuple[type[TypeError], type[ValueError]]:
    # Late, since the package's errors are defined in __init__.
    from . import KayaTypeError, KayaValueError
    return KayaTypeError, KayaValueError


def _length(length: str) -> int:
    code = _LENGTHS.get(length)
    if code is None:
        _, value_error = _errors()
        raise value_error(
            f"kaya: length {length!r} is not one of short, medium, long")
    return code


def _date(what: str, value: object) -> int:
    if isinstance(value, datetime.datetime) or not isinstance(value, datetime.date):
        type_error, _ = _errors()
        raise type_error(
            f"kaya: {what} is a datetime.date (year, month, day), not "
            f"{type(value).__name__} — the formatter takes civil components, "
            "never an instant")
    return wire.pack_date(value.year, value.month, value.day)


def _time(what: str, value: object) -> int:
    if not isinstance(value, datetime.time):
        type_error, _ = _errors()
        raise type_error(
            f"kaya: {what} is a datetime.time (hour, minute), not "
            f"{type(value).__name__}")
    return wire.pack_time(value.hour, value.minute)


def _number(what: str, value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        type_error, _ = _errors()
        raise type_error(
            f"kaya: {what} is a number, not {type(value).__name__}")
    return float(value)


def _digits(what: str, value: int | None) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 20:
        _, value_error = _errors()
        raise value_error(
            f"kaya: {what} is a digit count in 0..20, not {value!r}")
    return value


def date(value: datetime.date, *, length: Length = "medium") -> str:
    """The date, in the process locale."""
    return runtime.fmt_date(_date("fmt.date's value", value), _length(length))


def date_weekday(value: datetime.date) -> str:
    """The date with its weekday and no year (`Mon, Sep 7` in en-US)."""
    return runtime.fmt_date_weekday(_date("fmt.date_weekday's value", value))


def time(value: datetime.time, *, length: Length = "short") -> str:
    """The time, in the process locale and the user's hour cycle."""
    return runtime.fmt_time(_time("fmt.time's value", value), _length(length))


def date_time(date_value: datetime.date, time_value: datetime.time, *,
              length: Length = "medium") -> str:
    """The date and the time together, one length for both."""
    return runtime.fmt_date_time(_date("fmt.date_time's date", date_value),
                                 _time("fmt.date_time's time", time_value),
                                 _length(length))


def number(value: float, *, min_fraction_digits: int | None = None,
           max_fraction_digits: int | None = None, grouping: bool = True) -> str:
    """A number with the locale's separators; an unstated digit count is the
    platform's default."""
    return runtime.fmt_number(
        _number("fmt.number's value", value),
        _digits("min_fraction_digits", min_fraction_digits),
        _digits("max_fraction_digits", max_fraction_digits), bool(grouping))


def percent(value: float, *, min_fraction_digits: int | None = None,
            max_fraction_digits: int | None = None, grouping: bool = True) -> str:
    """A fraction as the locale's percentage: 0.256 is `26%` in en-US."""
    return runtime.fmt_percent(
        _number("fmt.percent's value", value),
        _digits("min_fraction_digits", min_fraction_digits),
        _digits("max_fraction_digits", max_fraction_digits), bool(grouping))


def currency(value: float, code: str) -> str:
    """An amount in the currency named by its ISO 4217 code (`USD`)."""
    if not isinstance(code, str) or len(code) != 3 or not code.isalpha():
        _, value_error = _errors()
        raise value_error(
            f"kaya: a currency is its three-letter ISO 4217 code, not {code!r}")
    return runtime.fmt_currency(_number("fmt.currency's value", value), code)


@dataclasses.dataclass(frozen=True)
class Locale:
    """Who the user is, as the platform reports it."""

    #: BCP-47, `en-US`.
    tag: str
    #: 12 or 24.
    hour_cycle: int
    #: 1 Monday … 7 Sunday.
    first_weekday: int
    #: CLDR's calendar name: `gregorian`, `japanese`, …
    calendar: str
    #: CLDR's numbering system: `latn`, `arab`, …
    numbering: str


def locale() -> Locale:
    """The process locale and its settings, asked of the platform each
    time."""
    tag, cycle, first, cal, numbering = runtime.locale_line().split(" ", 4)
    return Locale(tag, int(cycle), int(first), cal, numbering)


Direction = Literal["ltr", "rtl"]


def direction() -> Direction:
    """The layout direction the locale asks for."""
    return "rtl" if runtime.direction() == 1 else "ltr"


def text_scale() -> float:
    """The text scale the platform reported, 1.0 until one does."""
    return runtime.text_scale()
