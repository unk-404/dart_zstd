//! Deterministic benchmark slices and their libzstd reference frames.
//!
//! `bench-data` takes the first 256 KiB of four Silesia files, writes them to
//! `benchmark/bench_data/`, compresses each slice at level 3 and level 19 with
//! a content checksum, and embeds every file as base64 in
//! `benchmark/bench_data.g.dart` so the browser benchmark can run without
//! `dart:io`.
//!
//! Every frame is decoded again with libzstd before it is written, so a
//! generated data set is self-checking. Output is deterministic for a given
//! libzstd version: no timestamps or random seeds are involved.

use std::error::Error;
use std::fmt::Write as _;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use crate::base64;
use crate::{decode_bytes, encode_frame};

/// Size of one Silesia corpus slice, in bytes (256 KiB).
pub const SLICE_LEN: usize = 256 * 1024;

/// `(corpus id, source file name)` in the order used by the generated files.
pub const CORPORA: [(&str, &str); 4] = [
    ("dickens", "dickens"),
    ("xml", "xml"),
    ("x-ray", "x-ray"),
    ("osdb", "osdb"),
];

/// One corpus entry as stored in `manifest.json`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ManifestEntry {
    pub id: String,
    pub source: String,
    pub bytes: usize,
    pub plain: String,
    pub plain_bytes: usize,
    pub l3: String,
    pub l3_bytes: usize,
    pub l19: String,
    pub l19_bytes: usize,
}

pub const USAGE: &str = "\
zstd_ref bench-data [--out DIR] [--corpus DIR] [--dart-out FILE]

Takes the first 262144 bytes of dickens, xml, x-ray and osdb, writes
<corpus>.bin, <corpus>.l3.zst (libzstd level 3, checksum on),
<corpus>.l19.zst (level 19, checksum on) and manifest.json, then embeds all
of them in benchmark/bench_data.g.dart.

defaults:
    --out      benchmark/bench_data
    --corpus   benchmark/corpus/silesia
    --dart-out <parent of --out>/bench_data.g.dart
";

fn parse_args(args: &[String]) -> Result<(PathBuf, PathBuf, PathBuf), Box<dyn Error>> {
    let mut out = PathBuf::from("benchmark/bench_data");
    let mut corpus = PathBuf::from("benchmark/corpus/silesia");
    let mut dart_out: Option<PathBuf> = None;
    let mut index = 0;
    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "--out" | "--corpus" | "--dart-out" => {
                index += 1;
                let value = args
                    .get(index)
                    .cloned()
                    .ok_or_else(|| format!("{arg} needs a value"))?;
                match arg {
                    "--out" => out = PathBuf::from(value),
                    "--corpus" => corpus = PathBuf::from(value),
                    "--dart-out" => dart_out = Some(PathBuf::from(value)),
                    _ => unreachable!(),
                }
            }
            "--help" | "-h" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            other => return Err(format!("unknown option `{other}`\n\n{USAGE}").into()),
        }
        index += 1;
    }
    let dart_out = dart_out.unwrap_or_else(|| {
        out.parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."))
            .join("bench_data.g.dart")
    });
    Ok((out, corpus, dart_out))
}

pub fn generate(args: &[String]) -> Result<(), Box<dyn Error>> {
    let (out, corpus_dir, dart_out) = parse_args(args)?;
    if !corpus_dir.is_dir() {
        return Err(format!(
            "Silesia corpus not found at `{}` (pass --corpus DIR)",
            corpus_dir.display()
        )
        .into());
    }
    fs::create_dir_all(&out)?;

    let mut entries = Vec::with_capacity(CORPORA.len());
    let mut plain_files: Vec<(&'static str, Vec<u8>)> = Vec::with_capacity(CORPORA.len());
    let mut frames: Vec<(&'static str, Vec<u8>, Vec<u8>)> = Vec::with_capacity(CORPORA.len());

    for (id, source) in CORPORA {
        let source_path = corpus_dir.join(source);
        let plain = read_range(&source_path, 0, SLICE_LEN)?;
        let l3 = encode_frame(3, true, true, &[], &plain)?;
        let l19 = encode_frame(19, true, true, &[], &plain)?;

        for (level, frame) in [(3, &l3), (19, &l19)] {
            let decoded = decode_bytes(frame, &[]).map_err(|error| {
                format!(
                    "{}: libzstd could not decode the generated level-{level} frame: {error}",
                    source_path.display()
                )
            })?;
            if decoded != plain {
                return Err(format!(
                    "{}: level-{level} frame does not decode back to the slice",
                    source_path.display()
                )
                .into());
            }
        }

        let plain_name = format!("{id}.bin");
        let l3_name = format!("{id}.l3.zst");
        let l19_name = format!("{id}.l19.zst");
        write_file(&out.join(&plain_name), &plain)?;
        write_file(&out.join(&l3_name), &l3)?;
        write_file(&out.join(&l19_name), &l19)?;

        entries.push(ManifestEntry {
            id: id.to_string(),
            source: format!("benchmark/corpus/silesia/{source}"),
            bytes: plain.len(),
            plain: plain_name,
            plain_bytes: plain.len(),
            l3: l3_name,
            l3_bytes: l3.len(),
            l19: l19_name,
            l19_bytes: l19.len(),
        });
        plain_files.push((id, plain));
        frames.push((id, l3, l19));
    }

    let manifest = render_manifest(&entries);
    write_file(&out.join("manifest.json"), manifest.as_bytes())?;

    let dart = render_dart(&plain_files, &frames);
    if let Some(parent) = dart_out.parent() {
        fs::create_dir_all(parent)?;
    }
    write_file(&dart_out, dart.as_bytes())?;

    let plain_bytes: usize = entries.iter().map(|entry| entry.plain_bytes).sum();
    let frame_bytes: usize = entries
        .iter()
        .map(|entry| entry.l3_bytes + entry.l19_bytes)
        .sum();
    eprintln!(
        "zstd_ref: wrote {} corpora ({} plaintext bytes, {} frame bytes) to {}",
        entries.len(),
        plain_bytes,
        frame_bytes,
        out.display()
    );
    eprintln!(
        "zstd_ref: embedded {} files in {}",
        entries.len() * 3,
        dart_out.display()
    );
    Ok(())
}

fn write_file(path: &Path, data: &[u8]) -> io::Result<()> {
    fs::write(path, data)
}

fn read_range(path: &Path, offset: u64, len: usize) -> io::Result<Vec<u8>> {
    let mut file = fs::File::open(path)?;
    if offset > 0 {
        use std::io::{Seek, SeekFrom};
        file.seek(SeekFrom::Start(offset))?;
    }
    let mut data = Vec::with_capacity(len);
    file.take(len as u64).read_to_end(&mut data)?;
    if data.len() != len {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            format!(
                "{}: wanted {len} bytes at offset {offset}, found {}",
                path.display(),
                data.len()
            ),
        ));
    }
    Ok(data)
}

pub(crate) fn json_string(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len() + 2);
    escaped.push('"');
    for ch in value.chars() {
        match ch {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            ch if (ch as u32) < 0x20 => {
                let _ = write!(escaped, "\\u{:04x}", ch as u32);
            }
            ch => escaped.push(ch),
        }
    }
    escaped.push('"');
    escaped
}

fn render_manifest(entries: &[ManifestEntry]) -> String {
    let mut json = String::new();
    json.push_str("{\n");
    json.push_str("  \"version\": 1,\n");
    let _ = writeln!(json, "  \"sliceBytes\": {SLICE_LEN},");
    let _ = writeln!(
        json,
        "  \"libzstd\": {},",
        json_string(zstd::zstd_safe::version_string())
    );
    json.push_str("  \"corpora\": [\n");
    for (index, entry) in entries.iter().enumerate() {
        if index > 0 {
            json.push_str(",\n");
        }
        json.push_str("    {\n");
        let _ = writeln!(json, "      \"id\": {},", json_string(&entry.id));
        let _ = writeln!(json, "      \"source\": {},", json_string(&entry.source));
        let _ = writeln!(json, "      \"bytes\": {},", entry.bytes);
        let _ = writeln!(json, "      \"plain\": {},", json_string(&entry.plain));
        let _ = writeln!(json, "      \"plainBytes\": {},", entry.plain_bytes);
        let _ = writeln!(json, "      \"l3\": {},", json_string(&entry.l3));
        let _ = writeln!(json, "      \"l3Bytes\": {},", entry.l3_bytes);
        let _ = writeln!(json, "      \"l19\": {},", json_string(&entry.l19));
        let _ = writeln!(json, "      \"l19Bytes\": {}", entry.l19_bytes);
        json.push_str("    }");
    }
    json.push_str("\n  ]\n}\n");
    json
}

fn render_dart(
    plain_files: &[(&'static str, Vec<u8>)],
    frames: &[(&'static str, Vec<u8>, Vec<u8>)],
) -> String {
    let mut dart = String::new();
    dart.push_str(
        "// GENERATED FILE - DO NOT EDIT BY HAND.\n\
         //\n\
         // Regenerate with (from the repository root):\n\
         //   cargo run --release --manifest-path benchmark/rust_ref/Cargo.toml -- bench-data\n\
         //   dart format benchmark/bench_data.g.dart\n\
         //\n\
         // Deterministic 256 KiB slices of the Silesia corpus and their libzstd\n\
         // level-3 and level-19 frames (checksum on).\n\
         // See benchmark/corpus/README.md for provenance and licenses.\n\
         //\n\
         // This file imports nothing, so browser benchmarks can use it directly.\n\
         library;\n\n",
    );
    dart.push_str(
        "/// One embedded benchmark file: plaintext or a compressed frame.\n\
         final class BenchData {\n\
         \x20 const BenchData({\n\
         \x20   required this.corpus,\n\
         \x20   required this.kind,\n\
         \x20   required this.base64,\n\
         \x20   required this.length,\n\
         \x20 });\n\
         \n\
         \x20 /// Corpus id: `dickens`, `xml`, `x-ray` or `osdb`.\n\
         \x20 final String corpus;\n\
         \n\
         \x20 /// File kind: `plain`, `l3` or `l19`.\n\
         \x20 final String kind;\n\
         \n\
         \x20 /// Base64 of the file contents.\n\
         \x20 final String base64;\n\
         \n\
         \x20 /// Decoded length in bytes.\n\
         \x20 final int length;\n\
         }\n\n",
    );
    dart.push_str("/// Every benchmark input and frame, embedded as base64.\n");
    dart.push_str("const List<BenchData> benchData = <BenchData>[\n");
    for (corpus, plain) in plain_files {
        let Some((_, l3, l19)) = frames.iter().find(|(id, _, _)| id == corpus) else {
            continue;
        };
        for (kind, data) in [("plain", plain), ("l3", l3), ("l19", l19)] {
            let _ = writeln!(dart, "  BenchData(");
            let _ = writeln!(dart, "    corpus: '{corpus}',");
            let _ = writeln!(dart, "    kind: '{kind}',");
            let _ = writeln!(dart, "    base64: '{}',", base64::encode(data));
            let _ = writeln!(dart, "    length: {},", data.len());
            let _ = writeln!(dart, "  ),");
        }
    }
    dart.push_str("];\n");
    dart
}

/// Parses the `manifest.json` written by [`generate`].
///
/// The format is generated by this module, so a tiny field extractor is
/// enough; a full JSON parser would be a new dependency for no benefit.
pub fn parse_manifest(text: &str) -> Result<Vec<ManifestEntry>, Box<dyn Error>> {
    let corpora = text
        .find("\"corpora\"")
        .ok_or("manifest: missing \"corpora\"")?;
    let array_start = text[corpora..]
        .find('[')
        .map(|index| corpora + index)
        .ok_or("manifest: missing \"corpora\" array")?;
    let mut rest = &text[array_start + 1..];
    let mut entries = Vec::new();
    while let Some(open) = rest.find('{') {
        let close = rest[open..]
            .find('}')
            .ok_or("manifest: unterminated corpus object")?;
        let body = &rest[open + 1..open + close];
        entries.push(ManifestEntry {
            id: string_field(body, "id")?,
            source: string_field(body, "source")?,
            bytes: number_field(body, "bytes")? as usize,
            plain: string_field(body, "plain")?,
            plain_bytes: number_field(body, "plainBytes")? as usize,
            l3: string_field(body, "l3")?,
            l3_bytes: number_field(body, "l3Bytes")? as usize,
            l19: string_field(body, "l19")?,
            l19_bytes: number_field(body, "l19Bytes")? as usize,
        });
        rest = &rest[open + close + 1..];
    }
    if entries.is_empty() {
        return Err("manifest: no corpora entries".into());
    }
    Ok(entries)
}

fn string_field(object: &str, key: &str) -> Result<String, Box<dyn Error>> {
    let needle = format!("\"{key}\"");
    let start = object
        .find(&needle)
        .ok_or_else(|| format!("manifest: missing `{key}`"))?;
    let after = &object[start + needle.len()..];
    let colon = after
        .find(':')
        .ok_or_else(|| format!("manifest: `{key}` has no value"))?;
    let value = after[colon + 1..].trim_start();
    let value = value
        .strip_prefix('"')
        .ok_or_else(|| format!("manifest: `{key}` is not a string"))?;
    let end = value
        .find('"')
        .ok_or_else(|| format!("manifest: unterminated `{key}`"))?;
    Ok(value[..end].to_string())
}

fn number_field(object: &str, key: &str) -> Result<u64, Box<dyn Error>> {
    let needle = format!("\"{key}\"");
    let start = object
        .find(&needle)
        .ok_or_else(|| format!("manifest: missing `{key}`"))?;
    let after = &object[start + needle.len()..];
    let colon = after
        .find(':')
        .ok_or_else(|| format!("manifest: `{key}` has no value"))?;
    let value = after[colon + 1..].trim_start();
    let end = value
        .find(|ch: char| !ch.is_ascii_digit())
        .unwrap_or(value.len());
    if end == 0 {
        return Err(format!("manifest: `{key}` is not a number").into());
    }
    value[..end]
        .parse()
        .map_err(|error| format!("manifest: `{key}` is not a number: {error}").into())
}

#[cfg(test)]
mod tests {
    use super::{parse_manifest, render_manifest, ManifestEntry, SLICE_LEN};

    #[test]
    fn manifest_round_trips() {
        let entries = vec![ManifestEntry {
            id: "dickens".to_string(),
            source: "benchmark/corpus/silesia/dickens".to_string(),
            bytes: SLICE_LEN,
            plain: "dickens.bin".to_string(),
            plain_bytes: SLICE_LEN,
            l3: "dickens.l3.zst".to_string(),
            l3_bytes: 91_391,
            l19: "dickens.l19.zst".to_string(),
            l19_bytes: 58_620,
        }];
        let text = render_manifest(&entries);
        let parsed = parse_manifest(&text).expect("manifest parses");
        assert_eq!(parsed, entries);
    }

    #[test]
    fn manifest_rejects_empty_input() {
        assert!(parse_manifest("{}").is_err());
        assert!(parse_manifest("{\"corpora\": []}").is_err());
    }
}
