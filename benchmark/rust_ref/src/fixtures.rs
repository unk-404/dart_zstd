//! Deterministic generation of the interoperability fixtures under
//! `test/fixtures/`.
//!
//! Every frame is written together with the exact plaintext it must decode to
//! (`<name>.zst` + `<name>.bin`), and dictionary fixtures also get the
//! dictionary (`<name>.dict`). A small, deterministic subset is additionally
//! embedded as base64 in `fixtures.g.dart` so browser tests need no
//! `dart:io`.
//!
//! The generator is idempotent: running it twice with the same libzstd
//! produces byte-identical output.

use std::collections::BTreeMap;
use std::error::Error;
use std::fmt::Write as _;
use std::fs;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use crate::base64;
use crate::{decode_bytes, encode_frame};

/// Size of one Silesia corpus slice.
const SLICE_LEN: usize = 64 * 1024;
/// Largest fixture (zst + bin + dict) embedded in `fixtures.g.dart`.
const WEB_FIXTURE_BUDGET: usize = 32 * 1024;
/// Largest input-only fixture embedded in `fixtures.g.dart`.
const WEB_INPUT_BUDGET: usize = 8 * 1024;

/// A generated reference frame.
struct Built {
    name: String,
    zst: Vec<u8>,
    bin: Vec<u8>,
    dict: Option<Vec<u8>>,
}

/// A generated frame that must be rejected by a decoder.
struct Malformed {
    name: String,
    zst: Vec<u8>,
}

pub fn generate(args: &[String]) -> Result<(), Box<dyn Error>> {
    let (out, corpus, zstd_tests) = parse_args(args)?;
    if !corpus.is_dir() {
        return Err(format!(
            "Silesia corpus not found at `{}` (pass --corpus DIR)",
            corpus.display()
        )
        .into());
    }
    fs::create_dir_all(&out)?;

    let mut inputs = build_inputs();
    let mut built: Vec<Built> = Vec::new();
    let mut malformed: Vec<Malformed> = Vec::new();

    // --- Deterministic inputs -------------------------------------------------
    for (name, data) in &inputs {
        fs::write(out.join(format!("{name}.bin")), data)?;
    }

    // --- Silesia corpus slices ------------------------------------------------
    let mut silesia: BTreeMap<&'static str, Vec<u8>> = BTreeMap::new();
    for (key, file) in [
        ("dickens", "dickens"),
        ("xml", "xml"),
        ("xray", "x-ray"),
        ("osdb", "osdb"),
    ] {
        let data = read_range(&corpus.join(file), 0, SLICE_LEN)?;
        silesia.insert(key, data);
    }
    for (key, data) in &silesia {
        inputs.insert_owned(format!("silesia_{key}_64k"), data.clone());
    }

    // --- Compression-level matrix (text, 16 KiB so it stays browser-safe) -----
    let text_16k = inputs.get("text_16k").expect("text_16k input").clone();
    for level in [1, 3, 9, 19] {
        let zst = encode_frame(level, false, true, &[], &text_16k)?;
        push_frame(
            &mut built,
            &format!("text_16k_l{level}"),
            &text_16k,
            zst,
            None,
        );
    }

    // 256 KiB needs more than one block (max block = 128 KiB), so back
    // references cross block boundaries and the decoder's window handling is
    // exercised. Kept out of the base64 subset by its size.
    let text_256k = make_text(256 * 1024);
    push_frame(
        &mut built,
        "text_256k_l3",
        &text_256k,
        encode_frame(3, false, true, &[], &text_256k)?,
        None,
    );

    // --- Checksum / content-size matrix --------------------------------------
    let text_4k = inputs.get("text_4k").expect("text_4k input").clone();
    let json_4k = inputs.get("json_4k").expect("json_4k input").clone();

    push_frame(
        &mut built,
        "text_4k_checksum",
        &text_4k,
        encode_frame(3, true, true, &[], &text_4k)?,
        None,
    );
    push_frame(
        &mut built,
        "text_4k_nochecksum",
        &text_4k,
        encode_frame(3, false, true, &[], &text_4k)?,
        None,
    );
    push_frame(
        &mut built,
        "json_4k_contentsize",
        &json_4k,
        encode_frame(3, false, true, &[], &json_4k)?,
        None,
    );
    push_frame(
        &mut built,
        "json_4k_nocontentsize",
        &json_4k,
        encode_frame(3, false, false, &[], &json_4k)?,
        None,
    );

    // --- Concatenated frames --------------------------------------------------
    let split = text_16k.len() / 2;
    let mut multiframe = encode_frame(1, false, true, &[], &text_16k[..split])?;
    multiframe.extend_from_slice(&encode_frame(9, true, true, &[], &text_16k[split..])?);
    push_frame(&mut built, "multiframe", &text_16k, multiframe, None);

    // --- Skippable frames -----------------------------------------------------
    let mut skippable_prefix = skippable_frame(0, b"zstd_neo skippable frame, leading");
    skippable_prefix.extend_from_slice(&encode_frame(3, false, true, &[], &text_4k)?);
    push_frame(
        &mut built,
        "skippable_prefix",
        &text_4k,
        skippable_prefix,
        None,
    );

    let mut skippable_between = encode_frame(1, false, true, &[], &json_4k)?;
    skippable_between.extend_from_slice(&skippable_frame(1, b"middle skippable frame"));
    skippable_between.extend_from_slice(&encode_frame(3, true, true, &[], &text_4k)?);
    let mut skippable_between_bin = json_4k.clone();
    skippable_between_bin.extend_from_slice(&text_4k);
    push_frame(
        &mut built,
        "skippable_between",
        &skippable_between_bin,
        skippable_between,
        None,
    );

    // --- Silesia frames (level 3) --------------------------------------------
    for (key, data) in &silesia {
        let zst = encode_frame(3, false, true, &[], data)?;
        push_frame(&mut built, &format!("silesia_{key}_64k"), data, zst, None);
    }

    // --- Dictionaries ---------------------------------------------------------
    // Raw-content dictionary: 8 KiB of Dickens, plaintext from a later region.
    let training = read_range(&corpus.join("dickens"), 0, 256 * 1024)?;
    let raw_dictionary = training[..8 * 1024].to_vec();
    let raw_plaintext = read_range(&corpus.join("dickens"), 1_000_000, 16 * 1024)?;
    push_frame(
        &mut built,
        "rawdict",
        &raw_plaintext,
        encode_frame(3, false, true, &raw_dictionary, &raw_plaintext)?,
        Some(raw_dictionary),
    );

    // Structured dictionary trained with libzstd's dictionary builder.
    let samples: Vec<&[u8]> = training.chunks(4 * 1024).collect();
    let structured_dictionary = zstd::dict::from_samples(&samples, 8 * 1024)?;
    if structured_dictionary.len() < 8 || structured_dictionary[..4] != 0xEC30_A437u32.to_le_bytes()
    {
        return Err("zstd dictionary builder did not produce a structured dictionary".into());
    }
    let structured_plaintext = read_range(&corpus.join("dickens"), 2_000_000, 16 * 1024)?;
    push_frame(
        &mut built,
        "structdict",
        &structured_plaintext,
        encode_frame(
            3,
            false,
            true,
            &structured_dictionary,
            &structured_plaintext,
        )?,
        Some(structured_dictionary),
    );

    // --- Official zstd test vectors ------------------------------------------
    // Optional local checkout of the upstream zstd tests; CI never needs it.
    let golden_dir = zstd_tests.join("golden-decompression");
    if golden_dir.is_dir() {
        for (name, file) in [
            ("golden_block_128k", "block-128k.zst"),
            ("golden_empty_block", "empty-block.zst"),
            ("golden_rle_first_block", "rle-first-block.zst"),
            ("golden_zero_seq_2b", "zeroSeq_2B.zst"),
        ] {
            let zst = fs::read(golden_dir.join(file))?;
            let bin = decode_checked(name, &zst, &[])?;
            push_frame(&mut built, name, &bin, zst, None);
        }

        let error_dir = zstd_tests.join("golden-decompression-errors");
        for (name, file) in [
            ("malformed_off0", "off0.bin.zst"),
            ("malformed_truncated_huff_state", "truncated_huff_state.zst"),
            ("malformed_zero_seq_extraneous", "zeroSeq_extraneous.zst"),
        ] {
            let zst = fs::read(error_dir.join(file))?;
            if decode_bytes(&zst, &[]).is_ok() {
                return Err(format!(
                    "official error sample `{file}` unexpectedly decoded successfully"
                )
                .into());
            }
            malformed.push(Malformed {
                name: name.to_string(),
                zst,
            });
        }
    } else {
        eprintln!(
            "warning: `{}` not found; leaving official zstd samples untouched",
            golden_dir.display()
        );
    }

    // --- Validate every generated frame before writing it out ----------------
    for fixture in &built {
        let dictionary = fixture.dict.as_deref().unwrap_or(&[]);
        let decoded = decode_checked(&fixture.name, &fixture.zst, dictionary)?;
        if decoded != fixture.bin {
            return Err(format!(
                "libzstd round-trip mismatch for fixture `{}` ({} bytes decoded, {} expected)",
                fixture.name,
                decoded.len(),
                fixture.bin.len()
            )
            .into());
        }
    }

    // --- Write fixtures -------------------------------------------------------
    for fixture in &built {
        fs::write(out.join(format!("{}.zst", fixture.name)), &fixture.zst)?;
        fs::write(out.join(format!("{}.bin", fixture.name)), &fixture.bin)?;
        if let Some(dictionary) = &fixture.dict {
            fs::write(out.join(format!("{}.dict", fixture.name)), dictionary)?;
        }
    }
    for fixture in &malformed {
        fs::write(out.join(format!("{}.zst", fixture.name)), &fixture.zst)?;
    }

    // --- Browser-safe base64 constants ---------------------------------------
    let generated = build_generated(&built, &inputs, &malformed);
    fs::write(out.join("fixtures.g.dart"), generated)?;

    let raw_bytes: usize = built
        .iter()
        .map(|fixture| {
            fixture.zst.len() + fixture.bin.len() + fixture.dict.as_ref().map_or(0, Vec::len)
        })
        .sum();
    let web = built
        .iter()
        .filter(|fixture| web_fixture_included(fixture))
        .count();
    eprintln!(
        "zstd_ref: wrote {} fixtures ({} frames + {} malformed) to {}",
        built.len() + malformed.len(),
        built.len(),
        malformed.len(),
        out.display()
    );
    eprintln!(
        "zstd_ref: {} bytes of frame/plaintext/dictionary data, {} fixtures embedded in fixtures.g.dart (libzstd {})",
        raw_bytes,
        web,
        zstd::zstd_safe::version_string()
    );
    Ok(())
}

fn parse_args(args: &[String]) -> Result<(PathBuf, PathBuf, PathBuf), Box<dyn Error>> {
    let mut out = PathBuf::from("test/fixtures");
    let mut corpus = PathBuf::from("benchmark/corpus/silesia");
    let mut zstd_tests = PathBuf::from("test/zstd-tests");
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--out" => {
                index += 1;
                out = PathBuf::from(args.get(index).ok_or("--out needs a value")?);
            }
            "--corpus" => {
                index += 1;
                corpus = PathBuf::from(args.get(index).ok_or("--corpus needs a value")?);
            }
            "--zstd-tests" => {
                index += 1;
                zstd_tests = PathBuf::from(args.get(index).ok_or("--zstd-tests needs a value")?);
            }
            "--help" | "-h" => {
                println!(
                    "usage: zstd_ref gen-fixtures [--out DIR] [--corpus DIR] [--zstd-tests DIR]"
                );
                std::process::exit(0);
            }
            other => {
                return Err(format!("gen-fixtures: unknown argument `{other}`").into());
            }
        }
        index += 1;
    }
    Ok((out, corpus, zstd_tests))
}

fn build_inputs() -> Inputs {
    let mut inputs = Inputs::default();
    inputs.insert("empty", Vec::new());
    inputs.insert("one_byte", vec![0x00]);
    inputs.insert("three_bytes", b"abc".to_vec());
    inputs.insert("bytes_256", (0..=255u8).collect());
    inputs.insert("text_4k", make_text(4 * 1024));
    inputs.insert("json_4k", make_json(4 * 1024));
    inputs.insert("binary_4k", make_binary(4 * 1024));
    inputs.insert("text_16k", make_text(16 * 1024));
    inputs.insert("text_64k", make_text(64 * 1024));
    inputs.insert("json_64k", make_json(64 * 1024));
    inputs.insert("binary_64k", make_binary(64 * 1024));
    inputs.insert("zeros_64k", vec![0u8; 64 * 1024]);
    inputs.insert("random_64k", make_random(64 * 1024));
    inputs
}

/// Ordered input map so file output and generated Dart stay stable.
#[derive(Default)]
struct Inputs(BTreeMap<String, Vec<u8>>);

impl Inputs {
    fn insert(&mut self, name: &str, data: Vec<u8>) {
        self.0.insert(name.to_string(), data);
    }

    fn insert_owned(&mut self, name: String, data: Vec<u8>) {
        self.0.insert(name, data);
    }

    fn get(&self, name: &str) -> Option<&Vec<u8>> {
        self.0.get(name)
    }

    fn iter(&self) -> impl Iterator<Item = (&String, &Vec<u8>)> {
        self.0.iter()
    }
}

impl<'a> IntoIterator for &'a Inputs {
    type Item = (&'a String, &'a Vec<u8>);
    type IntoIter = std::collections::btree_map::Iter<'a, String, Vec<u8>>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.iter()
    }
}

fn push_frame(built: &mut Vec<Built>, name: &str, bin: &[u8], zst: Vec<u8>, dict: Option<Vec<u8>>) {
    built.push(Built {
        name: name.to_string(),
        zst,
        bin: bin.to_vec(),
        dict,
    });
}

/// `decode_bytes` with the fixture name in the error message.
fn decode_checked(name: &str, zst: &[u8], dictionary: &[u8]) -> io::Result<Vec<u8>> {
    decode_bytes(zst, dictionary).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("fixture `{name}` failed to decode: {error}"),
        )
    })
}

fn web_fixture_included(fixture: &Built) -> bool {
    let dict_len = fixture.dict.as_ref().map_or(0, Vec::len);
    fixture.zst.len() + fixture.bin.len() + dict_len <= WEB_FIXTURE_BUDGET
}

fn build_generated(built: &[Built], inputs: &Inputs, malformed: &[Malformed]) -> String {
    let mut dart = String::new();
    let _ = write!(
        dart,
        "// GENERATED FILE - DO NOT EDIT BY HAND.\n\
         //\n\
         // Regenerate with (from the repository root):\n\
         //   cargo run --release --manifest-path benchmark/rust_ref/Cargo.toml -- gen-fixtures\n\
         //   dart format test/fixtures/fixtures.g.dart\n\
         //\n\
         // Frames produced by libzstd {} through the `zstd` 0.14 Rust crate.\n\
         // See test/fixtures/README.md for provenance and licenses.\n\
         //\n\
         // This file imports nothing, so browser tests can use it directly.\n\
         library;\n\n",
        zstd::zstd_safe::version_string()
    );

    let _ = write!(
        dart,
        "/// A reference zstd frame together with the exact plaintext it must\n\
         /// decode to.\n\
         final class ZstdFixture {{\n\
         \x20 const ZstdFixture({{\n\
         \x20   required this.name,\n\
         \x20   required this.zstBase64,\n\
         \x20   required this.binBase64,\n\
         \x20   required this.zstLength,\n\
         \x20   required this.binLength,\n\
         \x20   this.dictBase64,\n\
         \x20   this.dictLength,\n\
         \x20 }});\n\
         \n\
         \x20 /// Stable fixture name; also the file stem under `test/fixtures/`.\n\
         \x20 final String name;\n\
         \n\
         \x20 /// Base64 of the `.zst` frame.\n\
         \x20 final String zstBase64;\n\
         \n\
         \x20 /// Base64 of the expected plaintext (the `.bin` file).\n\
         \x20 final String binBase64;\n\
         \n\
         \x20 /// Compressed frame length in bytes.\n\
         \x20 final int zstLength;\n\
         \n\
         \x20 /// Expected plaintext length in bytes.\n\
         \x20 final int binLength;\n\
         \n\
         \x20 /// Base64 of the `.dict` file, for dictionary frames.\n\
         \x20 final String? dictBase64;\n\
         \n\
         \x20 /// Dictionary length in bytes, when [dictBase64] is set.\n\
         \x20 final int? dictLength;\n\
         }}\n\n"
    );

    let _ = write!(
        dart,
        "/// A frame that a conforming decoder must reject.\n\
         final class ZstdMalformedFixture {{\n\
         \x20 const ZstdMalformedFixture({{\n\
         \x20   required this.name,\n\
         \x20   required this.zstBase64,\n\
         \x20   required this.zstLength,\n\
         \x20 }});\n\
         \n\
         \x20 /// Stable fixture name; also the file stem under `test/fixtures/`.\n\
         \x20 final String name;\n\
         \n\
         \x20 /// Base64 of the malformed `.zst` file.\n\
         \x20 final String zstBase64;\n\
         \n\
         \x20 /// Malformed frame length in bytes.\n\
         \x20 final int zstLength;\n\
         }}\n\n"
    );

    let _ = write!(
        dart,
        "/// A deterministic input with no matching frame, for encoder tests.\n\
         final class ZstdInput {{\n\
         \x20 const ZstdInput({{\n\
         \x20   required this.name,\n\
         \x20   required this.binBase64,\n\
         \x20   required this.binLength,\n\
         \x20 }});\n\
         \n\
         \x20 /// Stable input name; also the file stem under `test/fixtures/`.\n\
         \x20 final String name;\n\
         \n\
         \x20 /// Base64 of the plaintext input.\n\
         \x20 final String binBase64;\n\
         \n\
         \x20 /// Plaintext length in bytes.\n\
         \x20 final int binLength;\n\
         }}\n\n"
    );

    let mut web: Vec<&Built> = built.iter().filter(|f| web_fixture_included(f)).collect();
    web.sort_by(|a, b| a.name.cmp(&b.name));
    let _ = writeln!(
        dart,
        "/// Fixtures small enough to embed in browser tests\n\
         /// (frame + plaintext + dictionary <= {WEB_FIXTURE_BUDGET} bytes).\n\
         const List<ZstdFixture> webFixtures = <ZstdFixture>["
    );
    for fixture in &web {
        let _ = writeln!(dart, "  ZstdFixture(");
        let _ = writeln!(dart, "    name: '{}',", fixture.name);
        let _ = writeln!(dart, "    zstBase64: '{}',", base64::encode(&fixture.zst));
        let _ = writeln!(dart, "    binBase64: '{}',", base64::encode(&fixture.bin));
        let _ = writeln!(dart, "    zstLength: {},", fixture.zst.len());
        let _ = writeln!(dart, "    binLength: {},", fixture.bin.len());
        if let Some(dictionary) = &fixture.dict {
            let _ = writeln!(dart, "    dictBase64: '{}',", base64::encode(dictionary));
            let _ = writeln!(dart, "    dictLength: {},", dictionary.len());
        }
        let _ = writeln!(dart, "  ),");
    }
    let _ = writeln!(dart, "];\n");

    let mut web_inputs: Vec<(&String, &Vec<u8>)> = inputs
        .iter()
        .filter(|(_, data)| data.len() <= WEB_INPUT_BUDGET)
        .collect();
    web_inputs.sort_by(|a, b| a.0.cmp(b.0));
    let _ = writeln!(
        dart,
        "/// Deterministic inputs small enough to embed in browser tests.\n\
         const List<ZstdInput> webInputs = <ZstdInput>["
    );
    for (name, data) in &web_inputs {
        let _ = writeln!(dart, "  ZstdInput(");
        let _ = writeln!(dart, "    name: '{name}',");
        let _ = writeln!(dart, "    binBase64: '{}',", base64::encode(data));
        let _ = writeln!(dart, "    binLength: {},", data.len());
        let _ = writeln!(dart, "  ),");
    }
    let _ = writeln!(dart, "];\n");

    let mut malformed_sorted: Vec<&Malformed> = malformed.iter().collect();
    malformed_sorted.sort_by(|a, b| a.name.cmp(&b.name));
    let _ = writeln!(
        dart,
        "/// Official zstd malformed samples; a decoder must throw for each.\n\
         const List<ZstdMalformedFixture> malformedFixtures =\n\
         \x20   <ZstdMalformedFixture>["
    );
    for fixture in &malformed_sorted {
        let _ = writeln!(dart, "  ZstdMalformedFixture(");
        let _ = writeln!(dart, "    name: '{}',", fixture.name);
        let _ = writeln!(dart, "    zstBase64: '{}',", base64::encode(&fixture.zst));
        let _ = writeln!(dart, "    zstLength: {},", fixture.zst.len());
        let _ = writeln!(dart, "  ),");
    }
    let _ = writeln!(dart, "];");
    dart
}

// --- Deterministic content generators ---------------------------------------

fn splitmix64(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut value = *state;
    value = (value ^ (value >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    value ^ (value >> 31)
}

fn make_text(len: usize) -> Vec<u8> {
    const WORDS: [&str; 16] = [
        "the",
        "zstandard",
        "frame",
        "compression",
        "dart",
        "codec",
        "block",
        "sequence",
        "literal",
        "window",
        "stream",
        "decoder",
        "encoder",
        "checksum",
        "dictionary",
        "entropy",
    ];
    let mut text = String::with_capacity(len + 64);
    let mut index = 0usize;
    while text.len() < len {
        text.push_str(WORDS[index % WORDS.len()]);
        match index % 7 {
            0 => text.push_str(", "),
            3 => text.push_str(". "),
            5 => text.push_str(": "),
            _ => text.push(' '),
        }
        if index % 11 == 10 {
            text.push('\n');
        }
        index += 1;
    }
    text.truncate(len);
    text.into_bytes()
}

fn make_json(target: usize) -> Vec<u8> {
    let mut json = String::with_capacity(target + 128);
    json.push_str("[\n");
    let mut index = 0usize;
    loop {
        let record = format!(
            "  {{\"id\": {index}, \"name\": \"item-{index:04}\", \"value\": {}, \
\"tags\": [\"alpha\", \"beta\", \"gamma\"], \"active\": {}}}",
            (index * 7919) % 100_000,
            index % 3 != 0,
        );
        let separator = if index == 0 { "" } else { ",\n" };
        if json.len() + separator.len() + record.len() + 3 > target {
            break;
        }
        json.push_str(separator);
        json.push_str(&record);
        index += 1;
    }
    json.push_str("\n]\n");
    json.into_bytes()
}

fn make_binary(len: usize) -> Vec<u8> {
    let mut binary = Vec::with_capacity(len + 64);
    let mut state = 0x243F_6A88_85A3_08D3u64;
    let mut counter: u32 = 0;
    while binary.len() < len {
        binary.extend_from_slice(&counter.to_le_bytes());
        binary.extend_from_slice(&(counter.wrapping_mul(2_654_435_761)).to_le_bytes());
        let noise = splitmix64(&mut state);
        binary.extend_from_slice(&noise.to_le_bytes());
        binary.push((counter % 251) as u8);
        counter = counter.wrapping_add(1);
    }
    binary.truncate(len);
    binary
}

fn make_random(len: usize) -> Vec<u8> {
    let mut state = 0x9E37_79B9_7F4A_7C15u64;
    let mut random = Vec::with_capacity(len);
    while random.len() < len {
        random.extend_from_slice(&splitmix64(&mut state).to_le_bytes());
    }
    random.truncate(len);
    random
}

/// A skippable frame with magic `0x184D2A5x` and a deterministic payload.
fn skippable_frame(index: u32, payload: &[u8]) -> Vec<u8> {
    let magic = 0x184D_2A50u32 | ((index & 0xF) << 4);
    let mut frame = Vec::with_capacity(8 + payload.len());
    frame.extend_from_slice(&magic.to_le_bytes());
    frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    frame.extend_from_slice(payload);
    frame
}

fn read_range(path: &Path, offset: u64, len: usize) -> io::Result<Vec<u8>> {
    let mut file = fs::File::open(path)?;
    file.seek(SeekFrom::Start(offset))?;
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
