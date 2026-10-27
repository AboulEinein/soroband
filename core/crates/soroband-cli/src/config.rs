//! `soroband config`: reads and changes the settings the app uses, which apply at once.

use crate::data;
use serde_json::{Value, json};
use soroband_core::settings::{self, Current, Kind, SCHEMA, Setting, Settings};
use std::fmt::Write as _;
use std::path::Path;
use std::process::ExitCode;

pub const USAGE: &str = "\
Usage: soroband config list [--json]
       soroband config get <key> [--json]
       soroband config set <key> <value>

Settings live in settings.json in the app's data directory. `set` checks the
value against the setting's type and range, saves it, and tells the running
app, which applies it without a restart.";

pub fn run(args: &[&str]) -> ExitCode {
    let result = match args {
        ["list"] => list(false),
        ["list", "--json"] => list(true),
        ["get", key] => get(key, false),
        ["get", key, "--json"] => get(key, true),
        ["set", key, value] => set(key, value),
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(text) => {
            println!("{text}");
            ExitCode::SUCCESS
        }
        Err((code, message)) => {
            eprintln!("soroband config: {message}");
            ExitCode::from(code)
        }
    }
}

type Outcome = Result<String, (u8, String)>;

fn load() -> Result<(Settings, std::path::PathBuf), (u8, String)> {
    let path = data::directory()
        .map_err(|e| (1, e))?
        .join(settings::FILE_NAME);
    let settings = Settings::load(&path).map_err(|e| {
        (
            1,
            format!("{}: {e}. Fix or delete the file.", path.display()),
        )
    })?;
    Ok((settings, path))
}

fn describe(setting: &Setting, current: &Current) -> Value {
    let Kind::Integer { min, max } = setting.kind;
    let mut value = json!({
        "key": setting.key,
        "type": "integer",
        "min": min,
        "max": max,
        "default": setting.default,
        "value": current.value,
        "is_default": current.is_default,
        "description": setting.description,
    });
    if let Some(problem) = &current.problem {
        value["problem"] = json!(problem);
    }
    value
}

fn line(setting: &Setting, current: &Current) -> String {
    let Kind::Integer { min, max } = setting.kind;
    let mut text = format!(
        "{} = {}{}\n    integer {min}-{max}, default {}. {}",
        setting.key,
        current.value,
        if current.is_default { " (default)" } else { "" },
        setting.default,
        setting.description
    );
    if let Some(problem) = &current.problem {
        let _ = write!(text, "\n    warning: {problem}");
    }
    text
}

fn list(json: bool) -> Outcome {
    let (settings, _) = load()?;
    let mut rows = Vec::new();
    for setting in SCHEMA {
        let current = settings.get(setting.key).map_err(|e| (1, e.to_string()))?;
        rows.push((setting, current));
    }
    Ok(if json {
        Value::Array(rows.iter().map(|(s, c)| describe(s, c)).collect()).to_string()
    } else {
        rows.iter()
            .map(|(s, c)| line(s, c))
            .collect::<Vec<_>>()
            .join("\n")
    })
}

fn get(key: &str, json: bool) -> Outcome {
    let (settings, _) = load()?;
    let setting = settings::setting(key).ok_or_else(|| unknown(key))?;
    let current = settings.get(key).map_err(|e| (2, e.to_string()))?;
    Ok(if json {
        describe(setting, &current).to_string()
    } else {
        current.value.to_string()
    })
}

fn set(key: &str, value: &str) -> Outcome {
    let (mut settings, path) = load()?;
    settings.set(key, value).map_err(|e| match e {
        settings::Error::UnknownKey(_) => unknown(key),
        other => (2, other.to_string()),
    })?;
    save(&settings, &path)?;
    let current = settings.get(key).map_err(|e| (1, e.to_string()))?;
    let mut text = format!("{key} = {}", current.value);
    if let Err(error) = data::post_settings_changed() {
        let _ = write!(
            text,
            "\nSaved, but the running app was not told: {error}. It applies at the next launch."
        );
    }
    Ok(text)
}

fn save(settings: &Settings, path: &Path) -> Result<(), (u8, String)> {
    settings
        .save(path)
        .map_err(|e| (1, format!("cannot write {}: {e}", path.display())))
}

fn unknown(key: &str) -> (u8, String) {
    (2, settings::Error::UnknownKey(key.into()).to_string())
}
