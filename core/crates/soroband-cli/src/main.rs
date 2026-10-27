//! The `soroband` command.

#[cfg(debug_assertions)]
mod debug;
mod live;

use std::process::ExitCode;

const USAGE: &str = "\
Usage: soroband <command>

Commands:
  live                 Internet bytes per app, live (see soroband live --help)
  version              Print the version of the soroband command and its core
  help                 Print this help";

#[cfg(debug_assertions)]
const DEBUG_USAGE: &str = "
Debug builds only:
  debug state --json   Print what the running Debug app shows";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match args.as_slice() {
        ["version" | "--version" | "-V"] => {
            println!("soroband {}", soroband_core::version());
            ExitCode::SUCCESS
        }
        [] | ["help" | "--help" | "-h"] => {
            print_usage();
            ExitCode::SUCCESS
        }
        ["live", "--help" | "-h"] => {
            println!("{}", live::USAGE);
            ExitCode::SUCCESS
        }
        ["live", rest @ ..] => live::run(rest),
        #[cfg(debug_assertions)]
        ["debug", rest @ ..] => debug::run(rest),
        _ => {
            eprintln!("soroband: unknown command: {}\n", args.join(" "));
            print_usage();
            ExitCode::from(2)
        }
    }
}

fn print_usage() {
    println!("{USAGE}");
    #[cfg(debug_assertions)]
    println!("{DEBUG_USAGE}");
}
