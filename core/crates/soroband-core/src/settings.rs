//! Settings: one schema, stored as a flat JSON object in `settings.json` in the data directory.
//!
//! The core owns the schema. The app reads values through the core, and `soroband config` edits the
//! file and then posts a Darwin notification the app listens for, so a change applies without a
//! restart. A key missing from the file has its default; a stored value that does not fit the
//! schema is reported and replaced by the default; keys the schema does not know are kept.

// The errors are this module's [`Error`], whose variants say when each happens.
#![allow(clippy::missing_errors_doc)]

use serde_json::{Map, Value};
use std::fmt;
use std::io;
use std::path::Path;

/// File name of the settings in the data directory.
pub const FILE_NAME: &str = "settings.json";

/// Key of the hour of the day, local time, at which the daily counter resets.
pub const RESET_HOUR: &str = "reset_hour";
/// Key of whose usage the menu bar item counts: the current network's or every network's.
pub const MENU_BAR_SCOPE: &str = "menu_bar_scope";
/// The values of [`MENU_BAR_SCOPE`].
pub const MENU_BAR_SCOPE_OPTIONS: &[&str] = &["network", "all"];
/// Keys of the menu bar item's two lines. With one line shown it is drawn at the menu bar's
/// size; with two they are stacked in a smaller size; with none the item is its icon alone.
pub const MENU_BAR_TOP: &str = "menu_bar_top";
pub const MENU_BAR_BOTTOM: &str = "menu_bar_bottom";
/// What a menu bar line can show: today's bytes (total, download, upload), the live speed (both
/// directions, download, upload), or nothing.
pub const MENU_BAR_LINE_OPTIONS: &[&str] = &[
    "total",
    "download",
    "upload",
    "speed",
    "speed_down",
    "speed_up",
    "none",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A whole number from `min` to `max`, inclusive.
    Integer { min: i64, max: i64, default: i64 },
    /// One of a fixed set of words.
    Choice {
        options: &'static [&'static str],
        default: &'static str,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Setting {
    pub key: &'static str,
    pub kind: Kind,
    pub description: &'static str,
}

impl Setting {
    #[must_use]
    pub fn default_value(&self) -> Value {
        match self.kind {
            Kind::Integer { default, .. } => Value::from(default),
            Kind::Choice { default, .. } => Value::from(default),
        }
    }
}

/// Every setting.
pub const SCHEMA: &[Setting] = &[
    Setting {
        key: RESET_HOUR,
        kind: Kind::Integer {
            min: 0,
            max: 23,
            default: 0,
        },
        description: "Hour of the day (0-23, local time) when the daily counter starts again. \
                      History is not affected.",
    },
    Setting {
        key: MENU_BAR_SCOPE,
        kind: Kind::Choice {
            options: MENU_BAR_SCOPE_OPTIONS,
            default: "network",
        },
        description: "Whose usage today the menu bar item counts: network (the current \
                      network) or all (every network).",
    },
    Setting {
        key: MENU_BAR_TOP,
        kind: Kind::Choice {
            options: MENU_BAR_LINE_OPTIONS,
            default: "total",
        },
        description: "The menu bar item's first line: total, download or upload (today's \
                      bytes), speed, speed_down or speed_up (the live speed), or none.",
    },
    Setting {
        key: MENU_BAR_BOTTOM,
        kind: Kind::Choice {
            options: MENU_BAR_LINE_OPTIONS,
            default: "none",
        },
        description: "The menu bar item's second line, stacked under the first in a smaller \
                      size; the same options as menu_bar_top.",
    },
];

/// A value as `soroband config get` prints it and `soroband config set` takes it: words without
/// JSON quotes (`speed`), numbers as they are (`4`).
#[must_use]
pub fn plain(value: &Value) -> String {
    value
        .as_str()
        .map_or_else(|| value.to_string(), str::to_owned)
}

#[must_use]
pub fn setting(key: &str) -> Option<&'static Setting> {
    SCHEMA.iter().find(|s| s.key == key)
}

#[derive(Debug)]
pub enum Error {
    UnknownKey(String),
    InvalidValue {
        key: String,
        reason: String,
    },
    /// The file exists but is not a JSON object; it is left as it is.
    Unreadable(String),
    Io(io::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownKey(key) => write!(
                f,
                "unknown setting {key:?} (see `soroband config list` for the settings)"
            ),
            Self::InvalidValue { key, reason } => write!(f, "invalid value for {key}: {reason}"),
            Self::Unreadable(reason) => write!(f, "the settings file is not valid: {reason}"),
            Self::Io(error) => error.fmt(f),
        }
    }
}

impl std::error::Error for Error {}

impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// A setting's current value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Current {
    pub value: Value,
    /// True when the file does not set the key, or sets it to a value that does not fit.
    pub is_default: bool,
    /// Why the stored value was not used, when it does not fit the schema.
    pub problem: Option<String>,
}

/// The settings file's contents.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Settings {
    values: Map<String, Value>,
}

impl Settings {
    /// Reads the settings at `path`. A missing file gives every default.
    pub fn load(path: &Path) -> Result<Self, Error> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(error) => return Err(error.into()),
        };
        match serde_json::from_str(&text) {
            Ok(Value::Object(values)) => Ok(Self { values }),
            Ok(_) => Err(Error::Unreadable("it is not a JSON object".into())),
            Err(error) => Err(Error::Unreadable(error.to_string())),
        }
    }

    /// Writes the settings to `path` atomically, creating its directory.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let mut text = serde_json::to_string_pretty(&self.values).map_err(io::Error::other)?;
        text.push('\n');
        let temporary = path.with_extension("json.tmp");
        std::fs::write(&temporary, text)?;
        std::fs::rename(&temporary, path)
    }

    /// The current value of `key`.
    pub fn get(&self, key: &str) -> Result<Current, Error> {
        let setting = setting(key).ok_or_else(|| Error::UnknownKey(key.into()))?;
        Ok(match self.values.get(key) {
            None => Current {
                value: setting.default_value(),
                is_default: true,
                problem: None,
            },
            Some(stored) => match check(setting, stored) {
                Ok(value) => Current {
                    value,
                    is_default: false,
                    problem: None,
                },
                Err(reason) => Current {
                    value: setting.default_value(),
                    is_default: true,
                    problem: Some(format!("stored value {stored} ignored: {reason}")),
                },
            },
        })
    }

    /// Sets `key` from its text form, as typed on the command line.
    pub fn set(&mut self, key: &str, text: &str) -> Result<(), Error> {
        let setting = setting(key).ok_or_else(|| Error::UnknownKey(key.into()))?;
        let value = match setting.kind {
            Kind::Integer { .. } => {
                text.trim()
                    .parse::<i64>()
                    .map(Value::from)
                    .map_err(|_| Error::InvalidValue {
                        key: key.into(),
                        reason: format!("{text:?} is not a whole number"),
                    })?
            }
            Kind::Choice { .. } => Value::from(text.trim()),
        };
        check(setting, &value).map_err(|reason| Error::InvalidValue {
            key: key.into(),
            reason,
        })?;
        self.values.insert(key.into(), value);
        Ok(())
    }

    /// The hour of the day, local time, at which the daily counter resets.
    #[must_use]
    pub fn reset_hour(&self) -> u8 {
        self.get(RESET_HOUR)
            .ok()
            .and_then(|current| current.value.as_u64())
            .and_then(|hour| u8::try_from(hour).ok())
            .unwrap_or(0)
    }
}

fn check(setting: &Setting, value: &Value) -> Result<Value, String> {
    match setting.kind {
        Kind::Integer { min, max, .. } => {
            let number = value
                .as_i64()
                .ok_or_else(|| format!("{value} is not a whole number"))?;
            if (min..=max).contains(&number) {
                Ok(Value::from(number))
            } else {
                Err(format!("{number} is outside {min}-{max}"))
            }
        }
        Kind::Choice { options, .. } => match value.as_str() {
            Some(word) if options.contains(&word) => Ok(Value::from(word)),
            _ => Err(format!("{value} is not one of {}", options.join(", "))),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Error, MENU_BAR_BOTTOM, MENU_BAR_LINE_OPTIONS, MENU_BAR_SCOPE, MENU_BAR_TOP, RESET_HOUR,
        Settings,
    };
    use std::path::PathBuf;

    fn temp_file(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("soroband-settings-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir.join("settings.json")
    }

    #[test]
    fn missing_file_gives_a_midnight_reset() {
        let settings = Settings::load(&temp_file("missing")).unwrap();
        assert_eq!(settings.reset_hour(), 0);
        let current = settings.get(RESET_HOUR).unwrap();
        assert!(current.is_default);
        assert_eq!(current.problem, None);
    }

    #[test]
    fn set_value_survives_a_save_and_load() {
        let path = temp_file("round-trip");
        let mut settings = Settings::load(&path).unwrap();
        settings.set(RESET_HOUR, "4").unwrap();
        settings.save(&path).unwrap();
        let loaded = Settings::load(&path).unwrap();
        assert_eq!(loaded.reset_hour(), 4);
        assert!(!loaded.get(RESET_HOUR).unwrap().is_default);
        // The file is plain JSON an agent can read.
        let text = std::fs::read_to_string(&path).unwrap();
        assert_eq!(text, "{\n  \"reset_hour\": 4\n}\n");
    }

    #[test]
    fn reset_hour_must_be_an_hour_of_the_day() {
        let mut settings = Settings::default();
        for bad in ["24", "-1", "4.5", "four", ""] {
            assert!(
                matches!(
                    settings.set(RESET_HOUR, bad),
                    Err(Error::InvalidValue { .. })
                ),
                "{bad:?} was accepted"
            );
        }
        settings.set(RESET_HOUR, "23").unwrap();
        assert_eq!(settings.reset_hour(), 23);
        settings.set(RESET_HOUR, "0").unwrap();
        assert_eq!(settings.reset_hour(), 0);
        assert!(!settings.get(RESET_HOUR).unwrap().is_default);
    }

    #[test]
    fn unknown_key_is_refused() {
        let mut settings = Settings::default();
        assert!(matches!(
            settings.set("reset_houre", "4"),
            Err(Error::UnknownKey(_))
        ));
        assert!(matches!(
            settings.get("reset_houre"),
            Err(Error::UnknownKey(_))
        ));
    }

    #[test]
    fn stored_value_out_of_range_falls_back_to_the_default_and_says_why() {
        let path = temp_file("out-of-range");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, r#"{"reset_hour": 30, "from_the_future": true}"#).unwrap();
        let mut settings = Settings::load(&path).unwrap();
        assert_eq!(settings.reset_hour(), 0);
        let current = settings.get(RESET_HOUR).unwrap();
        assert!(current.is_default);
        assert_eq!(
            current.problem.as_deref(),
            Some("stored value 30 ignored: 30 is outside 0-23")
        );
        // Keys from a newer Soroband are kept when another setting is saved.
        settings.set(RESET_HOUR, "5").unwrap();
        settings.save(&path).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("\"from_the_future\": true"), "{text}");
    }

    #[test]
    fn a_settings_path_that_cannot_be_read_is_an_error_not_the_defaults() {
        // A directory where the file should be: reading fails with something other than
        // "not found", which must not pass for an empty settings file.
        let path = temp_file("directory");
        std::fs::create_dir_all(&path).unwrap();
        assert!(matches!(Settings::load(&path), Err(Error::Io(_))));
    }

    #[test]
    fn errors_name_the_key_and_the_reason() {
        let mut settings = Settings::default();
        let unknown = settings.set("reset_houre", "4").unwrap_err().to_string();
        assert!(
            unknown.contains("\"reset_houre\"") && unknown.contains("soroband config list"),
            "{unknown}"
        );
        let invalid = settings.set(RESET_HOUR, "24").unwrap_err().to_string();
        assert_eq!(invalid, "invalid value for reset_hour: 24 is outside 0-23");
        assert_eq!(
            Error::Unreadable("it is not a JSON object".into()).to_string(),
            "the settings file is not valid: it is not a JSON object"
        );
    }

    #[test]
    fn unreadable_file_is_reported_not_replaced() {
        let path = temp_file("unreadable");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        for text in ["{\"reset_hour\": ", "[4]"] {
            std::fs::write(&path, text).unwrap();
            assert!(
                matches!(Settings::load(&path), Err(Error::Unreadable(_))),
                "{text:?} loaded"
            );
        }
    }

    /// A fresh install shows today's total on the current network on one line, as before the
    /// two lines existed.
    #[test]
    fn menu_bar_shows_todays_total_on_the_current_network_on_one_line_unless_set() {
        let settings = Settings::default();
        assert_eq!(settings.get(MENU_BAR_SCOPE).unwrap().value, "network");
        assert_eq!(settings.get(MENU_BAR_TOP).unwrap().value, "total");
        assert_eq!(settings.get(MENU_BAR_BOTTOM).unwrap().value, "none");
    }

    #[test]
    fn menu_bar_lines_accept_only_their_options() {
        let mut settings = Settings::default();
        for option in MENU_BAR_LINE_OPTIONS {
            settings.set(MENU_BAR_BOTTOM, option).unwrap();
            assert_eq!(settings.get(MENU_BAR_BOTTOM).unwrap().value, *option);
        }
        settings.set(MENU_BAR_TOP, "download").unwrap();
        for bad in ["Download", "both", "", "4"] {
            let error = settings.set(MENU_BAR_TOP, bad).unwrap_err().to_string();
            assert!(
                error.contains("total, download, upload, speed, speed_down, speed_up, none"),
                "{bad:?}: {error}"
            );
        }
        assert_eq!(
            settings.get(MENU_BAR_TOP).unwrap().value,
            "download",
            "a refused value changes nothing"
        );
        assert!(settings.set(MENU_BAR_SCOPE, "today_all").is_err());
    }

    #[test]
    fn stored_menu_bar_value_from_a_hand_edit_falls_back_to_the_default() {
        let path = temp_file("menu-bar-hand-edit");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, r#"{"menu_bar_top": "rainbow"}"#).unwrap();
        let settings = Settings::load(&path).unwrap();
        assert_eq!(settings.get(MENU_BAR_TOP).unwrap().value, "total");
        let current = settings.get(MENU_BAR_TOP).unwrap();
        assert!(current.is_default);
        assert!(
            current
                .problem
                .unwrap()
                .contains("\"rainbow\" is not one of")
        );
    }
}
