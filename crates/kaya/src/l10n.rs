//! The catalog (docs/compliance-plan.md §2.4): the app's words in each
//! language it ships, Fluent files `l10n/<app>.<locale>.ftl` under the asset root,
//! resolved here with the process locale's fallback chain, every embedded
//! value formatted through the fmt door. A missing message or argument is
//! a panic naming the key and the locale; the platform never sees a
//! catalog.

use crate::protocol::{Date, Time};
use fluent_bundle::concurrent::FluentBundle;
use fluent_bundle::{FluentArgs, FluentResource, FluentValue};
use std::sync::Mutex;

/// One argument to a message: what a Fluent placeable may hold.
#[derive(Clone, Debug, PartialEq)]
pub enum Arg {
    Int(i64),
    Float(f64),
    Str(String),
    Date(Date),
    Time(Time),
}

impl From<i64> for Arg {
    fn from(v: i64) -> Self {
        Arg::Int(v)
    }
}
impl From<i32> for Arg {
    fn from(v: i32) -> Self {
        Arg::Int(v as i64)
    }
}
impl From<usize> for Arg {
    fn from(v: usize) -> Self {
        Arg::Int(v as i64)
    }
}
impl From<f64> for Arg {
    fn from(v: f64) -> Self {
        Arg::Float(v)
    }
}
impl From<&str> for Arg {
    fn from(v: &str) -> Self {
        Arg::Str(v.to_owned())
    }
}
impl From<String> for Arg {
    fn from(v: String) -> Self {
        Arg::Str(v)
    }
}
impl From<Date> for Arg {
    fn from(v: Date) -> Self {
        Arg::Date(v)
    }
}
impl From<Time> for Arg {
    fn from(v: Time) -> Self {
        Arg::Time(v)
    }
}

/// `tr!("key", name = value, ...)`: the lookup, spelled for Rust.
#[macro_export]
macro_rules! tr {
    ($key:expr) => { $crate::l10n::tr($key, &[]) };
    ($key:expr, $($name:ident = $value:expr),+ $(,)?) => {
        $crate::l10n::tr($key, &[ $((stringify!($name), $crate::l10n::Arg::from($value))),+ ])
    };
}

struct Catalog {
    app: String,
    locale: String,
    bundle: FluentBundle<FluentResource>,
}

static CATALOG: Mutex<Option<Catalog>> = Mutex::new(None);

/// A date carried through a message as itself, written through the door
/// at the medium length unless `DATETIME($d, length: "…")` says otherwise.
#[derive(Debug, Clone, Copy, PartialEq)]
struct DateValue(Date);
#[derive(Debug, Clone, Copy, PartialEq)]
struct TimeValue(Time);

impl fluent_bundle::types::FluentType for DateValue {
    fn duplicate(&self) -> Box<dyn fluent_bundle::types::FluentType + Send> {
        Box::new(*self)
    }
    fn as_string(&self, _: &intl_memoizer::IntlLangMemoizer) -> std::borrow::Cow<'static, str> {
        crate::fmt::date(self.0, crate::fmt::Length::Medium).into()
    }
    fn as_string_threadsafe(
        &self,
        _: &intl_memoizer::concurrent::IntlLangMemoizer,
    ) -> std::borrow::Cow<'static, str> {
        crate::fmt::date(self.0, crate::fmt::Length::Medium).into()
    }
}

impl fluent_bundle::types::FluentType for TimeValue {
    fn duplicate(&self) -> Box<dyn fluent_bundle::types::FluentType + Send> {
        Box::new(*self)
    }
    fn as_string(&self, _: &intl_memoizer::IntlLangMemoizer) -> std::borrow::Cow<'static, str> {
        crate::fmt::time(self.0, crate::fmt::Length::Short).into()
    }
    fn as_string_threadsafe(
        &self,
        _: &intl_memoizer::concurrent::IntlLangMemoizer,
    ) -> std::borrow::Cow<'static, str> {
        crate::fmt::time(self.0, crate::fmt::Length::Short).into()
    }
}

fn length_named(name: Option<&FluentValue<'_>>) -> crate::fmt::Length {
    match name {
        Some(FluentValue::String(s)) if s == "short" => crate::fmt::Length::Short,
        Some(FluentValue::String(s)) if s == "long" => crate::fmt::Length::Long,
        _ => crate::fmt::Length::Medium,
    }
}

/// A number's placeable goes through the door, never Fluent's own
/// English digits; a custom value writes itself (the two types above).
fn through_the_door(value: &FluentValue<'_>, _: &intl_memoizer::concurrent::IntlLangMemoizer) -> Option<String> {
    match value {
        FluentValue::Number(n) => {
            let options = crate::fmt::NumberOptions {
                min_fraction_digits: n.options.minimum_fraction_digits.map(|d| d as u8),
                max_fraction_digits: n.options.maximum_fraction_digits.map(|d| d as u8),
                grouping: n.options.use_grouping,
            };
            Some(crate::fmt::number(n.value, options))
        }
        _ => None,
    }
}

/// Load the app's catalog for the process locale: `l10n/<app>.<tag>.ftl`, then the
/// language alone, then the default the identity manifest declares. Called
/// once at startup by the app; every binding spells it.
pub fn catalog(app: &str) {
    crate::fmt::install_locale_knob();
    let locale = crate::fmt::locale().tag;
    let default = crate::scene::declared_default_locale();
    let mut chain: Vec<String> = vec![locale.clone()];
    if let Some((language, _)) = locale.split_once('-') {
        chain.push(language.to_owned());
    }
    if !chain.contains(&default) {
        chain.push(default.clone());
    }
    let mut tried = Vec::new();
    for candidate in &chain {
        let name = format!("l10n/{app}.{candidate}.ftl");
        match crate::assets::read(&name) {
            Ok(bytes) => {
                let text = String::from_utf8(bytes).unwrap_or_else(|_| {
                    panic!("kaya: the catalog \"{name}\" is not UTF-8")
                });
                let resource = FluentResource::try_new(text).unwrap_or_else(|(_, errors)| {
                    panic!(
                        "kaya: the catalog \"{name}\" does not parse: {}",
                        errors.iter().map(|e| e.to_string()).collect::<Vec<_>>().join("; ")
                    )
                });
                let lang: unic_langid::LanguageIdentifier = candidate
                    .parse()
                    .unwrap_or_else(|_| panic!("kaya: \"{candidate}\" is not a language tag"));
                let mut bundle = FluentBundle::new_concurrent(vec![lang]);
                // Isolation marks off: the platform's formatters carry their
                // own bidi marks, and a scene compares a label's bytes
                // (docs/compliance-plan.md §2.4).
                bundle.set_use_isolating(false);
                bundle.set_formatter(Some(through_the_door));
                bundle
                    .add_function("DATETIME", |positional, named| match positional.first() {
                        Some(FluentValue::Custom(c)) => {
                            let any: &dyn std::any::Any = c.as_ref().as_any();
                            if let Some(d) = any.downcast_ref::<DateValue>() {
                                // `length: "weekday"` is the task list's idiom,
                                // the door's date_weekday (docs/compliance-plan.md §6).
                                let weekday = matches!(named.get("length"), Some(FluentValue::String(s)) if s == "weekday");
                                FluentValue::String(if weekday {
                                    crate::fmt::date_weekday(d.0).into()
                                } else {
                                    crate::fmt::date(d.0, length_named(named.get("length"))).into()
                                })
                            } else if let Some(t) = any.downcast_ref::<TimeValue>() {
                                // A time's unstated length is SHORT, as the bare
                                // placeable's is: the tasks leg read `8:30:00 AM`
                                // for `DATETIME($time)` on 2026-09-23.
                                let length = if named.get("length").is_some() {
                                    length_named(named.get("length"))
                                } else {
                                    crate::fmt::Length::Short
                                };
                                FluentValue::String(crate::fmt::time(t.0, length).into())
                            } else {
                                FluentValue::Error
                            }
                        }
                        _ => FluentValue::Error,
                    })
                    .expect("a fresh bundle has no DATETIME");
                bundle
                    .add_function("NUMBER", |positional, named| match positional.first() {
                        Some(FluentValue::Number(n)) => {
                            let digits = |key: &str| match named.get(key) {
                                Some(FluentValue::Number(d)) => Some(d.value as u8),
                                _ => None,
                            };
                            let options = crate::fmt::NumberOptions {
                                min_fraction_digits: digits("minimumFractionDigits"),
                                max_fraction_digits: digits("maximumFractionDigits"),
                                grouping: !matches!(named.get("useGrouping"), Some(FluentValue::String(s)) if s == "false"),
                            };
                            FluentValue::String(crate::fmt::number(n.value, options).into())
                        }
                        _ => FluentValue::Error,
                    })
                    .expect("a fresh bundle has no NUMBER");
                bundle.add_resource(resource).unwrap_or_else(|errors| {
                    panic!(
                        "kaya: the catalog \"{name}\" declares a message twice: {}",
                        errors.iter().map(|e| e.to_string()).collect::<Vec<_>>().join("; ")
                    )
                });
                *CATALOG.lock().unwrap_or_else(|e| e.into_inner()) =
                    Some(Catalog { app: app.to_owned(), locale: candidate.clone(), bundle });
                return;
            }
            Err(_) => tried.push(name),
        }
    }
    panic!(
        "kaya: no catalog for \"{app}\" — the process locale is {locale}, the manifest's \
         default_locale is \"{default}\", and none of {} is under the asset root \
         (docs/compliance-plan.md §2.4)",
        tried.join(", ")
    );
}

/// The catalog's locale, for the harness and the curious: `None` before
/// `catalog()`.
pub fn catalog_locale() -> Option<String> {
    CATALOG.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|c| c.locale.clone())
}

/// The message `key` with `args` filled, in the loaded catalog.
pub fn tr(key: &str, args: &[(&str, Arg)]) -> String {
    let guard = CATALOG.lock().unwrap_or_else(|e| e.into_inner());
    let Some(catalog) = guard.as_ref() else {
        panic!("kaya: tr({key:?}) before catalog(): an app names its catalog once at startup");
    };
    let message = catalog.bundle.get_message(key).unwrap_or_else(|| {
        panic!(
            "kaya: the catalog \"{}\" ({}) has no message {key:?}",
            catalog.app, catalog.locale
        )
    });
    let pattern = message.value().unwrap_or_else(|| {
        panic!(
            "kaya: the message {key:?} in \"{}\" ({}) has attributes and no value",
            catalog.app, catalog.locale
        )
    });
    let mut fluent_args = FluentArgs::new();
    for (name, arg) in args {
        let value: FluentValue<'_> = match arg {
            Arg::Int(i) => FluentValue::from(*i),
            Arg::Float(f) => FluentValue::from(*f),
            Arg::Str(s) => FluentValue::from(s.as_str()),
            Arg::Date(d) => FluentValue::Custom(Box::new(DateValue(*d))),
            Arg::Time(t) => FluentValue::Custom(Box::new(TimeValue(*t))),
        };
        fluent_args.set(*name, value);
    }
    let mut errors = Vec::new();
    let out = catalog.bundle.format_pattern(pattern, Some(&fluent_args), &mut errors);
    if !errors.is_empty() {
        panic!(
            "kaya: the message {key:?} in \"{}\" ({}) did not resolve: {}",
            catalog.app,
            catalog.locale,
            errors.iter().map(|e| e.to_string()).collect::<Vec<_>>().join("; ")
        );
    }
    out.into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bundle_of(lang: &str, ftl: &str) -> Catalog {
        let resource = FluentResource::try_new(ftl.to_owned()).expect("parses");
        let mut bundle = FluentBundle::new_concurrent(vec![lang.parse().unwrap()]);
        bundle.set_use_isolating(false);
        bundle.set_formatter(Some(through_the_door));
        bundle.add_resource(resource).expect("no duplicates");
        Catalog { app: "test".into(), locale: lang.into(), bundle }
    }

    fn with_catalog<T>(c: Catalog, f: impl FnOnce() -> T) -> T {
        let _serial = crate::assets::serially();
        *CATALOG.lock().unwrap_or_else(|e| e.into_inner()) = Some(c);
        let out = f();
        *CATALOG.lock().unwrap_or_else(|e| e.into_inner()) = None;
        out
    }

    const ARABIC: &str = "tasks-due = { $count ->\n    [zero] لا مهام\n    [one] مهمة واحدة\n    [two] مهمتان\n    [few] { $count } مهام\n    [many] { $count } مهمة\n   *[other] { $count } مهمة\n}\n";

    #[test]
    fn the_six_arabic_forms_are_chosen_by_cldr_s_rules() {
        with_catalog(bundle_of("ar-EG", ARABIC), || {
            let form = |n: i64| tr("tasks-due", &[("count", Arg::Int(n))]);
            assert_eq!(form(0), "لا مهام");
            assert_eq!(form(1), "مهمة واحدة");
            assert_eq!(form(2), "مهمتان");
            assert!(form(3).ends_with("مهام"), "{}", form(3));
            assert!(form(11).ends_with("مهمة"), "{}", form(11));
            assert!(form(100).ends_with("مهمة"), "{}", form(100));
        });
    }

    #[test]
    fn english_has_two_forms_and_a_plain_argument() {
        with_catalog(
            bundle_of("en-US", "items = { $count ->\n    [one] one item in { $list }\n   *[other] { $count } items in { $list }\n}\nhello = Hello, { $name }!\n"),
            || {
                assert_eq!(tr("items", &[("count", 1.into()), ("list", "Inbox".into())]), "one item in Inbox");
                assert_eq!(tr!("hello", name = "Ada"), "Hello, Ada!");
            },
        );
    }

    #[test]
    #[should_panic(expected = "has no message \"missing\"")]
    fn a_missing_message_panics_naming_the_key_and_the_locale() {
        with_catalog(bundle_of("en-US", "hello = hi\n"), || {
            tr("missing", &[]);
        });
    }

    #[test]
    #[should_panic(expected = "did not resolve")]
    fn a_missing_argument_panics() {
        with_catalog(bundle_of("en-US", "hello = Hello, { $name }!\n"), || {
            tr("hello", &[]);
        });
    }

    #[test]
    #[should_panic(expected = "before catalog()")]
    fn tr_before_catalog_panics() {
        let _serial = crate::assets::serially();
        *CATALOG.lock().unwrap_or_else(|e| e.into_inner()) = None;
        tr("hello", &[]);
    }

    /// The door inside a message: the number's digits and separators are
    /// the platform's, not Fluent's (this Mac's locale, so the shape is
    /// held loosely).
    #[cfg(target_os = "macos")]
    #[test]
    fn a_number_placeable_goes_through_the_door() {
        with_catalog(bundle_of("en-US", "big = { $n } things\ndated = due { $d }\n"), || {
            let s = tr("big", &[("n", Arg::Int(1234567))]);
            assert!(s.contains("567") && s.ends_with(" things"), "{s}");
            let d = tr("dated", &[("d", Arg::Date(Date::new(2026, 9, 7).unwrap()))]);
            assert!(d.starts_with("due ") && d.len() > 4, "{d}");
            assert_eq!(&d[4..], crate::fmt::date(Date::new(2026, 9, 7).unwrap(), crate::fmt::Length::Medium));
        });
    }
}
