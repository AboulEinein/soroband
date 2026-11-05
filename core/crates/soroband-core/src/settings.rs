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
/// Key of the readings the menu bar item shows beside its icon, in order: up to
/// [`MENU_BAR_MAX_READINGS`] of [`MENU_BAR_READING_OPTIONS`], or `none` for the icon alone.
pub const MENU_BAR_READINGS: &str = "menu_bar_readings";
/// What the menu bar item can show: today's bytes (total, download, upload) or the live speed
/// (download, upload).
pub const MENU_BAR_READING_OPTIONS: &[&str] =
    &["total", "download", "upload", "speed_down", "speed_up"];
pub const MENU_BAR_MAX_READINGS: usize = 4;
/// Key of how the menu bar item draws its readings: stacked in pairs, each under a caption, or on
/// one line.
pub const MENU_BAR_STYLE: &str = "menu_bar_style";
/// The values of [`MENU_BAR_STYLE`].
pub const MENU_BAR_STYLE_OPTIONS: &[&str] = &["stacked", "labeled", "inline"];

/// Key of the island's master switch: off makes Soroband a plain menu bar app.
pub const ISLAND: &str = "island";
pub const ON_OFF: &[&str] = &["on", "off"];
/// Key of how the island opens: seamless (over the menu bar beside the notch) or clear (notch-wide
/// in the menu bar, widening only below it).
pub const ISLAND_STYLE: &str = "island_style";
pub const ISLAND_STYLE_OPTIONS: &[&str] = &["seamless", "clear"];
/// Key of the moments the island shows.
pub const ISLAND_MOMENTS: &str = "island_moments";
pub const ISLAND_MOMENT_OPTIONS: &[&str] = &[
    "peek",
    "joined",
    "left",
    "hotspot",
    "hog",
    "background",
    "transfer",
    "recap",
];
pub const ISLAND_HOG_MB: &str = "island_hog_mb";
pub const ISLAND_HOG_MINUTES: &str = "island_hog_minutes";
pub const ISLAND_BACKGROUND_MB: &str = "island_background_mb";
pub const ISLAND_TRANSFER_MB: &str = "island_transfer_mb";
/// Key of whether a data hog on a hotspot offers Pause until off hotspot.
pub const ISLAND_PAUSE: &str = "island_pause";
/// Key of what the island shows while an app is full screen.
pub const ISLAND_FULL_SCREEN: &str = "island_full_screen";
pub const ISLAND_FULL_SCREEN_OPTIONS: &[&str] = &["hide", "alerts", "all"];
/// Key of the displays the island shows on.
pub const ISLAND_DISPLAYS: &str = "island_displays";
pub const ISLAND_DISPLAYS_OPTIONS: &[&str] = &["builtin", "all"];
/// Key of whether alerts become notifications while the island is off.
pub const ISLAND_NOTIFICATIONS: &str = "island_notifications";
/// Key of the apps that raise no moment, by app id.
pub const ISLAND_IGNORED_APPS: &str = "island_ignored_apps";
pub const ISLAND_MAX_IGNORED_APPS: usize = 100;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A whole number from `min` to `max`, inclusive.
    Integer { min: i64, max: i64, default: i64 },
    /// One of a fixed set of words.
    Choice {
        options: &'static [&'static str],
        default: &'static str,
    },
    /// Up to `max` different words of `options`, in order, separated by commas; `none` for no word.
    List {
        options: &'static [&'static str],
        max: usize,
        default: &'static str,
    },
    /// Up to `max` different names of any text without a comma, separated by commas; `none` for
    /// no name.
    Names { max: usize },
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
            Kind::Choice { default, .. } | Kind::List { default, .. } => Value::from(default),
            Kind::Names { .. } => Value::from("none"),
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
        key: MENU_BAR_READINGS,
        kind: Kind::List {
            options: MENU_BAR_READING_OPTIONS,
            max: MENU_BAR_MAX_READINGS,
            default: "total",
        },
        description: "What the menu bar item shows beside its icon, in order, separated by \
                      commas: up to 4 of total, download, upload (today's bytes), speed_down and \
                      speed_up (the live speed); none for the icon alone.",
    },
    Setting {
        key: MENU_BAR_STYLE,
        kind: Kind::Choice {
            options: MENU_BAR_STYLE_OPTIONS,
            default: "stacked",
        },
        description: "How the menu bar item draws its readings: stacked (in pairs, the first \
                      on top, in a smaller size), labeled (each under a small caption) or inline \
                      (one line).",
    },
    Setting {
        key: ISLAND,
        kind: Kind::Choice {
            options: ON_OFF,
            default: "off",
        },
        description: "Whether the island at the notch shows moments: on, or off for a plain menu bar \
                      app.",
    },
    Setting {
        key: ISLAND_STYLE,
        kind: Kind::Choice {
            options: ISLAND_STYLE_OPTIONS,
            default: "seamless",
        },
        description: "How the island opens: seamless (over the menu bar beside the notch) or clear \
                      (notch-wide in the menu bar, widening only below it).",
    },
    Setting {
        key: ISLAND_MOMENTS,
        kind: Kind::List {
            options: ISLAND_MOMENT_OPTIONS,
            max: ISLAND_MOMENT_OPTIONS.len(),
            default: "peek,joined,left,hotspot,hog,background,transfer",
        },
        description: "The moments the island shows, separated by commas: peek, joined, left, \
                      hotspot, hog, background, transfer, recap; none for no moment.",
    },
    Setting {
        key: ISLAND_HOG_MB,
        kind: Kind::Integer {
            min: 1,
            max: 100_000,
            default: 100,
        },
        description: "Megabytes one app must use within island_hog_minutes to be a data hog.",
    },
    Setting {
        key: ISLAND_HOG_MINUTES,
        kind: Kind::Integer {
            min: 1,
            max: 60,
            default: 5,
        },
        description: "Minutes the data hog and background activity look back over.",
    },
    Setting {
        key: ISLAND_BACKGROUND_MB,
        kind: Kind::Integer {
            min: 1,
            max: 100_000,
            default: 50,
        },
        description: "Megabytes an app not in front must use within island_hog_minutes to show \
                      background activity.",
    },
    Setting {
        key: ISLAND_TRANSFER_MB,
        kind: Kind::Integer {
            min: 1,
            max: 100_000,
            default: 50,
        },
        description: "Megabytes a transfer reaches before the island shows its progress.",
    },
    Setting {
        key: ISLAND_PAUSE,
        kind: Kind::Choice {
            options: ON_OFF,
            default: "on",
        },
        description: "Whether a data hog on a hotspot offers Pause until off hotspot, which quits the \
                      app and opens it again on the next network that is not a hotspot.",
    },
    Setting {
        key: ISLAND_FULL_SCREEN,
        kind: Kind::Choice {
            options: ISLAND_FULL_SCREEN_OPTIONS,
            default: "alerts",
        },
        description: "What the island shows while an app is full screen: hide (nothing), alerts \
                      (data hog and background activity only) or all.",
    },
    Setting {
        key: ISLAND_DISPLAYS,
        kind: Kind::Choice {
            options: ISLAND_DISPLAYS_OPTIONS,
            default: "builtin",
        },
        description: "Where the island shows: builtin (the built-in display) or all (every \
                      display).",
    },
    Setting {
        key: ISLAND_NOTIFICATIONS,
        kind: Kind::Choice {
            options: ON_OFF,
            default: "on",
        },
        description: "Whether data hog and background activity alerts become notifications while \
                      the island is off.",
    },
    Setting {
        key: ISLAND_IGNORED_APPS,
        kind: Kind::Names {
            max: ISLAND_MAX_IGNORED_APPS,
        },
        description: "Apps that raise no moment, by app id (a bundle path such as \
                      /Applications/Music.app, or a tool's path), separated by commas; none for \
                      no app.",
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
            Kind::Choice { .. } | Kind::List { .. } | Kind::Names { .. } => {
                Value::from(text.trim())
            }
        };
        let value = check(setting, &value).map_err(|reason| Error::InvalidValue {
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
        Kind::List { options, max, .. } => {
            let text = value
                .as_str()
                .ok_or_else(|| format!("{value} is not a list of words"))?;
            if text.trim() == "none" {
                return Ok(Value::from("none"));
            }
            let words: Vec<&str> = text.split(',').map(str::trim).collect();
            if let Some(word) = words.iter().find(|word| !options.contains(word)) {
                return Err(format!(
                    "{word:?} is not one of {} (or none)",
                    options.join(", ")
                ));
            }
            if words.len() > max {
                return Err(format!("{} words, at most {max}", words.len()));
            }
            if let Some(index) = (1..words.len()).find(|&i| words[..i].contains(&words[i])) {
                return Err(format!("{:?} is listed twice", words[index]));
            }
            Ok(Value::from(words.join(",")))
        }
        Kind::Names { max } => {
            let text = value
                .as_str()
                .ok_or_else(|| format!("{value} is not a list of names"))?;
            if text.trim() == "none" {
                return Ok(Value::from("none"));
            }
            let names: Vec<&str> = text.split(',').map(str::trim).collect();
            if names.iter().any(|name| name.is_empty()) {
                return Err("an empty name".into());
            }
            if names.len() > max {
                return Err(format!("{} names, at most {max}", names.len()));
            }
            if let Some(index) = (1..names.len()).find(|&i| names[..i].contains(&names[i])) {
                return Err(format!("{:?} is listed twice", names[index]));
            }
            Ok(Value::from(names.join(",")))
        }
    }
}

impl Settings {
    /// The value of the `on`/`off` setting `key`.
    #[must_use]
    pub fn is_on(&self, key: &str) -> bool {
        self.get(key)
            .is_ok_and(|current| current.value.as_str() == Some("on"))
    }

    /// The value of the whole-number setting `key`, or 0 for a key that is not one.
    #[must_use]
    pub fn number(&self, key: &str) -> u64 {
        self.get(key)
            .ok()
            .and_then(|current| current.value.as_u64())
            .unwrap_or(0)
    }

    /// The words or names of the list setting `key`; none for `none`.
    #[must_use]
    pub fn words(&self, key: &str) -> Vec<String> {
        let Ok(current) = self.get(key) else {
            return Vec::new();
        };
        match current.value.as_str() {
            None | Some("none") => Vec::new(),
            Some(text) => text.split(',').map(str::to_owned).collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Error, ISLAND, ISLAND_IGNORED_APPS, ISLAND_MOMENTS, MENU_BAR_READINGS, MENU_BAR_SCOPE,
        MENU_BAR_STYLE, RESET_HOUR, Settings,
    };
    use std::path::PathBuf;

    fn temp_file(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("soroband-settings-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir.join("settings.json")
    }

    #[test]
    fn a_fresh_install_has_the_island_off_and_every_moment_but_the_recap() {
        // The user decided (2026-10-28) that the first run is a plain menu bar app; the daily
        // recap is off by default (design.md, Dynamic Island moments).
        let settings = Settings::load(&temp_file("island-defaults")).unwrap();
        assert!(!settings.is_on(ISLAND));
        let moments = settings.words(ISLAND_MOMENTS);
        assert_eq!(moments.len(), 7);
        assert!(!moments.contains(&"recap".to_owned()));
    }

    #[test]
    fn ignored_apps_take_any_name_without_a_comma() {
        let mut settings = Settings::default();
        settings
            .set(
                ISLAND_IGNORED_APPS,
                " /Applications/Music.app , macOS & Services",
            )
            .unwrap();
        assert_eq!(
            settings.words(ISLAND_IGNORED_APPS),
            ["/Applications/Music.app", "macOS & Services"]
        );
        for bad in ["/Applications/Music.app,,curl", "curl,curl"] {
            assert!(
                matches!(
                    settings.set(ISLAND_IGNORED_APPS, bad),
                    Err(Error::InvalidValue { .. })
                ),
                "{bad:?} is refused"
            );
        }
        let hundred_and_one: Vec<String> = (0..=100).map(|i| format!("/tmp/tool{i}")).collect();
        assert!(
            settings
                .set(ISLAND_IGNORED_APPS, &hundred_and_one.join(","))
                .is_err()
        );
        let hundred = &hundred_and_one[..100];
        assert!(
            settings
                .set(ISLAND_IGNORED_APPS, &hundred.join(","))
                .is_ok()
        );
        settings.set(ISLAND_IGNORED_APPS, "none").unwrap();
        assert_eq!(settings.words(ISLAND_IGNORED_APPS), Vec::<String>::new());
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

    /// A fresh install shows today's total on the current network.
    #[test]
    fn menu_bar_shows_todays_total_on_the_current_network_unless_set() {
        let settings = Settings::default();
        assert_eq!(settings.get(MENU_BAR_SCOPE).unwrap().value, "network");
        assert_eq!(settings.get(MENU_BAR_READINGS).unwrap().value, "total");
        assert_eq!(settings.get(MENU_BAR_STYLE).unwrap().value, "stacked");
    }

    /// Readings are kept in the order given, which is the order the item draws them in.
    #[test]
    fn menu_bar_readings_are_up_to_four_different_options_in_order() {
        let mut settings = Settings::default();
        settings
            .set(MENU_BAR_READINGS, "speed_up, download,total")
            .unwrap();
        assert_eq!(
            settings.get(MENU_BAR_READINGS).unwrap().value,
            "speed_up,download,total"
        );
        settings.set(MENU_BAR_READINGS, "none").unwrap();
        assert_eq!(settings.get(MENU_BAR_READINGS).unwrap().value, "none");
        for (bad, reason) in [
            (
                "speed",
                "\"speed\" is not one of total, download, upload, speed_down, speed_up",
            ),
            ("", "\"\" is not one of"),
            ("total,", "\"\" is not one of"),
            ("total,none", "\"none\" is not one of"),
            ("download,download", "\"download\" is listed twice"),
            (
                "total,download,upload,speed_down,speed_up",
                "5 words, at most 4",
            ),
        ] {
            let error = settings
                .set(MENU_BAR_READINGS, bad)
                .unwrap_err()
                .to_string();
            assert!(error.contains(reason), "{bad:?}: {error}");
        }
        assert_eq!(
            settings.get(MENU_BAR_READINGS).unwrap().value,
            "none",
            "a refused value changes nothing"
        );
        assert!(settings.set(MENU_BAR_STYLE, "stacked").is_ok());
        assert!(settings.set(MENU_BAR_STYLE, "vertical").is_err());
        assert!(settings.set(MENU_BAR_SCOPE, "today_all").is_err());
    }

    #[test]
    fn stored_menu_bar_value_from_a_hand_edit_falls_back_to_the_default() {
        let path = temp_file("menu-bar-hand-edit");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, r#"{"menu_bar_readings": "total,rainbow"}"#).unwrap();
        let settings = Settings::load(&path).unwrap();
        let current = settings.get(MENU_BAR_READINGS).unwrap();
        assert_eq!(current.value, "total");
        assert!(current.is_default);
        assert!(
            current
                .problem
                .unwrap()
                .contains("\"rainbow\" is not one of")
        );
    }
}
