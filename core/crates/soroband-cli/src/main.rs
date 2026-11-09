//! The `soroband` command.

mod config;
mod data;
#[cfg(debug_assertions)]
mod debug;
mod live;
mod text;
mod update;
mod usage;

use std::process::ExitCode;

const USAGE: &str = "\
Usage: soroband <command>

Commands:
  today                Today's usage per network (see soroband today --help)
  apps                 Today's usage per app, on one network or all (see soroband apps --help)
  config               List, read and change settings (see soroband config --help)
  live                 Internet bytes per app, live (see soroband live --help)
  update               Install the newest release (see soroband update --help)
  version              Print the version and the commit the soroband command was built from
  help                 Print this help";

#[cfg(debug_assertions)]
const DEBUG_USAGE: &str = "
Debug builds only:
  debug state --json   Print what the running Debug app shows
  debug history --json Print what the Debug app's History window shows";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match args.as_slice() {
        ["version" | "--version" | "-V"] => {
            println!("soroband {}", version_line());
            ExitCode::SUCCESS
        }
        [] | ["help" | "--help" | "-h"] => {
            print_usage();
            ExitCode::SUCCESS
        }
        ["today", "--help" | "-h"] => {
            println!("{}", usage::TODAY_USAGE);
            ExitCode::SUCCESS
        }
        ["today", rest @ ..] => usage::today(rest),
        ["apps", "--help" | "-h"] => {
            println!("{}", usage::APPS_USAGE);
            ExitCode::SUCCESS
        }
        ["apps", rest @ ..] => usage::apps(rest),
        ["config", "--help" | "-h"] | ["config"] => {
            println!("{}", config::USAGE);
            ExitCode::SUCCESS
        }
        ["config", rest @ ..] => config::run(rest),
        ["live", "--help" | "-h"] => {
            println!("{}", live::USAGE);
            ExitCode::SUCCESS
        }
        ["live", rest @ ..] => live::run(rest),
        ["update", "--help" | "-h"] => {
            println!("{}", update::USAGE);
            ExitCode::SUCCESS
        }
        ["update", rest @ ..] => update::run(rest),
        #[cfg(debug_assertions)]
        ["debug", rest @ ..] => debug::run(rest),
        _ => {
            eprintln!("soroband: unknown command: {}\n", args.join(" "));
            print_usage();
            ExitCode::from(2)
        }
    }
}

/// The version, the build number and the build stamp, as Settings › About shows them:
/// `0.1.0 (412) · 16e85ce main`. The build number counts the commits up to the stamped one.
fn version_line() -> String {
    let stamp = [env!("SOROBAND_COMMIT"), env!("SOROBAND_BRANCH")]
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        "{} ({}) · {stamp}",
        soroband_core::version(),
        env!("SOROBAND_BUILD")
    )
}

fn print_usage() {
    println!("{USAGE}");
    #[cfg(debug_assertions)]
    println!("{DEBUG_USAGE}");
}
