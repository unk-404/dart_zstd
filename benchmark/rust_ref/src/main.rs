//! `zstd_ref` — dev-only reference tool for the pure-Dart `zstd_neo` codec.
//!
//! It does three things:
//!
//! * `encode` a file with libzstd (optionally with checksum, without the
//!   frame content size, or with a dictionary);
//! * `decode` a file with libzstd;
//! * `gen-fixtures` regenerate the committed interoperability fixtures under
//!   `test/fixtures/`, including the browser-safe `fixtures.g.dart`.
//!
//! Nothing here is part of the published Dart package. The default
//! `dart test` path never builds or runs this binary; only the dedicated
//! interop job points `ZSTD_REF` at it.

mod base64;
mod fixtures;

use std::env;
use std::error::Error;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

const USAGE: &str = "\
zstd_ref — dev-only reference tool for the pure-Dart zstd_neo codec

USAGE:
    zstd_ref encode <in> <out> [--level N] [--checksum] [--no-content-size]
                               [--dictionary FILE]
    zstd_ref decode <in> <out> [--dictionary FILE]
    zstd_ref gen-fixtures [--out DIR] [--corpus DIR] [--zstd-tests DIR]
    zstd_ref version

encode defaults:
    --level 3            zstd compression level (1..=22)
    content size         included (single-segment frame header)
    --checksum           append the 4-byte XXH64 content checksum
    --no-content-size    omit Frame_Content_Size from the frame header
    --dictionary FILE    raw-content or structured zstd dictionary

gen-fixtures defaults:
    --out test/fixtures              output directory
    --corpus benchmark/corpus/silesia Silesia corpus root
    --zstd-tests test/zstd-tests      official zstd test vectors (optional)

The output of `gen-fixtures` is deterministic for a given libzstd version.";

fn main() {
    if let Err(error) = run() {
        eprintln!("zstd_ref: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        println!("{USAGE}");
        return Ok(());
    };
    let rest: Vec<String> = args.collect();

    match command.as_str() {
        "encode" => encode_cli(&rest),
        "decode" => decode_cli(&rest),
        "gen-fixtures" => fixtures::generate(&rest),
        "version" | "--version" | "-V" => {
            println!(
                "zstd_ref {} (zstd crate 0.14, libzstd {})",
                env!("CARGO_PKG_VERSION"),
                zstd::zstd_safe::version_string()
            );
            Ok(())
        }
        "help" | "--help" | "-h" => {
            println!("{USAGE}");
            Ok(())
        }
        other => Err(format!("unknown command `{other}`\n\n{USAGE}").into()),
    }
}

/// Options shared by the file-oriented commands.
#[derive(Debug)]
struct Options {
    positional: Vec<String>,
    level: i32,
    checksum: bool,
    content_size: bool,
    dictionary: Option<PathBuf>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            positional: Vec::new(),
            level: 3,
            checksum: false,
            content_size: true,
            dictionary: None,
        }
    }
}

fn parse_options(args: &[String]) -> Result<Options, Box<dyn Error>> {
    let mut options = Options::default();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        match arg.as_str() {
            "--level" => {
                index += 1;
                let value = args.get(index).ok_or("--level needs a value")?;
                options.level = value.parse()?;
            }
            "--checksum" => options.checksum = true,
            "--no-content-size" => options.content_size = false,
            "--dictionary" => {
                index += 1;
                let value = args.get(index).ok_or("--dictionary needs a path")?;
                options.dictionary = Some(PathBuf::from(value));
            }
            other if other.starts_with("--level=") => {
                options.level = other["--level=".len()..].parse()?;
            }
            other if other.starts_with("--dictionary=") => {
                options.dictionary = Some(PathBuf::from(&other["--dictionary=".len()..]));
            }
            other if other.starts_with("--") => {
                return Err(format!("unknown option `{other}`").into());
            }
            _ => options.positional.push(arg.clone()),
        }
        index += 1;
    }
    Ok(options)
}

fn two_paths<'a>(
    options: &'a Options,
    command: &str,
) -> Result<(&'a Path, &'a Path), Box<dyn Error>> {
    match options.positional.as_slice() {
        [input, output] => Ok((Path::new(input), Path::new(output))),
        _ => Err(format!("`{command}` needs exactly <in> <out>").into()),
    }
}

fn encode_cli(args: &[String]) -> Result<(), Box<dyn Error>> {
    let options = parse_options(args)?;
    let (input, output) = two_paths(&options, "encode")?;
    let data = fs::read(input)?;
    let dictionary = read_dictionary(&options)?;

    let frame = encode_frame(
        options.level,
        options.checksum,
        options.content_size,
        &dictionary,
        &data,
    )?;
    write_output(output, &frame)?;
    eprintln!(
        "zstd_ref: encoded {} bytes -> {} ({} bytes, level {}, checksum {}, content-size {})",
        data.len(),
        output.display(),
        frame.len(),
        options.level,
        if options.checksum { "on" } else { "off" },
        if options.content_size { "on" } else { "off" },
    );
    Ok(())
}

fn decode_cli(args: &[String]) -> Result<(), Box<dyn Error>> {
    let options = parse_options(args)?;
    let (input, output) = two_paths(&options, "decode")?;
    let data = fs::read(input)?;
    let dictionary = read_dictionary(&options)?;

    let decoded = decode_bytes(&data, &dictionary)?;
    write_output(output, &decoded)?;
    eprintln!(
        "zstd_ref: decoded {} bytes -> {} ({} bytes)",
        data.len(),
        output.display(),
        decoded.len(),
    );
    Ok(())
}

fn read_dictionary(options: &Options) -> Result<Vec<u8>, Box<dyn Error>> {
    match &options.dictionary {
        Some(path) => Ok(fs::read(path)?),
        None => Ok(Vec::new()),
    }
}

fn write_output(path: &Path, data: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)?;
        }
    }
    fs::write(path, data)
}

/// Compresses `data` into one complete zstd frame.
///
/// `dictionary` may be empty, a raw-content dictionary, or a structured
/// (trained) dictionary; libzstd auto-detects which.
pub fn encode_frame(
    level: i32,
    checksum: bool,
    include_content_size: bool,
    dictionary: &[u8],
    data: &[u8],
) -> io::Result<Vec<u8>> {
    let mut compressor = if dictionary.is_empty() {
        zstd::bulk::Compressor::new(level)?
    } else {
        zstd::bulk::Compressor::with_dictionary(level, dictionary)?
    };
    compressor.include_checksum(checksum)?;
    compressor.include_contentsize(include_content_size)?;
    // Makes the content-size decision explicit instead of relying on
    // `ZSTD_compress2` inferring it.
    compressor.set_pledged_src_size(Some(data.len() as u64))?;
    compressor.compress(data)
}

/// Decodes a byte slice: single frame, concatenated frames, and skippable
/// frames are all handled by libzstd.
pub fn decode_bytes(data: &[u8], dictionary: &[u8]) -> io::Result<Vec<u8>> {
    let cursor = io::Cursor::new(data);
    let mut decoder = if dictionary.is_empty() {
        zstd::stream::Decoder::with_buffer(cursor)?
    } else {
        zstd::stream::Decoder::with_dictionary(cursor, dictionary)?
    };
    let mut decoded = Vec::new();
    decoder.read_to_end(&mut decoded)?;
    Ok(decoded)
}

#[cfg(test)]
mod tests {
    use super::{decode_bytes, encode_frame};

    const SAMPLE: &[u8] = b"the quick brown fox jumps over the lazy dog, \
repeated enough times to produce a compressed block: the quick brown fox \
jumps over the lazy dog. zstd zstd zstd zstd zstd zstd zstd zstd zstd.";

    #[test]
    fn round_trip_levels() {
        for level in [1, 3, 9, 19] {
            for checksum in [false, true] {
                for content_size in [false, true] {
                    let frame = encode_frame(level, checksum, content_size, &[], SAMPLE).unwrap();
                    let decoded = decode_bytes(&frame, &[]).unwrap();
                    assert_eq!(decoded, SAMPLE);
                }
            }
        }
    }

    #[test]
    fn round_trip_empty_input() {
        let frame = encode_frame(3, false, true, &[], &[]).unwrap();
        assert_eq!(decode_bytes(&frame, &[]).unwrap(), Vec::<u8>::new());
    }

    #[test]
    fn round_trip_raw_dictionary() {
        let dictionary = b"the quick brown fox jumps over the lazy dog";
        let frame = encode_frame(3, false, true, dictionary, SAMPLE).unwrap();
        assert!(
            decode_bytes(&frame, &[]).is_err(),
            "dictionary must be required"
        );
        assert_eq!(decode_bytes(&frame, dictionary).unwrap(), SAMPLE);
    }

    #[test]
    fn multi_frame_concatenation() {
        let first = encode_frame(1, false, true, &[], b"first frame ").unwrap();
        let second = encode_frame(3, false, true, &[], b"and a second frame").unwrap();
        let mut stream = first;
        stream.extend_from_slice(&second);
        assert_eq!(
            decode_bytes(&stream, &[]).unwrap(),
            b"first frame and a second frame"
        );
    }
}
