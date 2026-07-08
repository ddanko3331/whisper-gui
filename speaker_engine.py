#!/usr/bin/env python3
"""
Lightweight, completely local Speaker Recognition & Diarization Engine.
Extracts 16-band spectral voice print signatures using built-in wave module
and standard math routines (no external dependencies required like PyTorch/numpy).
Slices and analyzes WAV audio files entirely in-memory for maximum performance.
"""

import sys
import os
import math
import wave
import json
import struct
from pathlib import Path
from typing import List, Tuple, Optional

# Config directory for saving speaker signatures
CONFIG_DIR = Path.home() / ".config" / "whisper-gui"
SPEAKERS_DIR = CONFIG_DIR / "speakers"

# Try importing sherpa_onnx
SHERPA_AVAILABLE = False
try:
    import sherpa_onnx
    SHERPA_AVAILABLE = True
except ImportError:
    pass

MODEL_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
MODEL_PATH = CONFIG_DIR / "models" / "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"

_extractor_cache = None

def download_model(url: str, dest_path: Path) -> None:
    import urllib.request
    print(f"Downloading pre-trained speaker model from {url}...", file=sys.stderr)
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = dest_path.with_suffix(".tmp")
    try:
        with urllib.request.urlopen(url) as response, open(temp_path, "wb") as out_file:
            meta = response.info()
            file_size = int(meta.get("Content-Length", 0))
            print(f"File size: {file_size / (1024*1024):.2f} MB", file=sys.stderr)
            
            downloaded = 0
            block_size = 8192
            while True:
                buffer = response.read(block_size)
                if not buffer:
                    break
                downloaded += len(buffer)
                out_file.write(buffer)
                if file_size > 0:
                    percent = downloaded * 100 / file_size
                    if downloaded % (block_size * 500) == 0 or downloaded == file_size:
                        print(f"Progress: {percent:.1f}%", file=sys.stderr)
        temp_path.rename(dest_path)
        print("✔ Model downloaded successfully!", file=sys.stderr)
    except Exception as e:
        if temp_path.exists():
            temp_path.unlink()
        print(f"Error downloading model: {e}", file=sys.stderr)
        raise e

def get_sherpa_extractor():
    global _extractor_cache
    if _extractor_cache is not None:
        return _extractor_cache
    if not SHERPA_AVAILABLE:
        return None
    if not MODEL_PATH.is_file():
        try:
            download_model(MODEL_URL, MODEL_PATH)
        except Exception as e:
            print(f"Warning: Could not download Sherpa-ONNX model, falling back. Error: {e}", file=sys.stderr)
            return None
    try:
        config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(MODEL_PATH),
            num_threads=1,
            debug=False,
            provider="cpu"
        )
        _extractor_cache = sherpa_onnx.SpeakerEmbeddingExtractor(config)
        return _extractor_cache
    except Exception as e:
        print(f"Warning: Failed to initialize Sherpa-ONNX extractor: {e}", file=sys.stderr)
        return None

def get_speakers_dir() -> Path:
    if get_sherpa_extractor() is not None:
        d = SPEAKERS_DIR / "sherpa"
        d.mkdir(parents=True, exist_ok=True)
        return d
    return SPEAKERS_DIR

def get_similarity_threshold() -> float:
    if get_sherpa_extractor() is not None:
        return 0.65
    return 0.70

def ensure_dirs() -> None:
    get_speakers_dir().mkdir(parents=True, exist_ok=True)

def read_wav_samples(wav_path: str) -> Tuple[List[float], int]:
    """Reads a WAV file and returns (samples_normalized_to_[-1, 1], framerate)."""
    try:
        with wave.open(wav_path, "rb") as w:
            nchannels = w.getnchannels()
            sampwidth = w.getsampwidth()
            framerate = w.getframerate()
            nframes = w.getnframes()
            
            # Read raw frames
            raw_data = w.readframes(nframes)
            
        samples = []
        if sampwidth == 2:
            # 16-bit signed integer
            fmt = f"<{nframes * nchannels}h"
            raw_ints = struct.unpack(fmt, raw_data)
            # Take mono (if stereo, take left channel)
            for i in range(0, len(raw_ints), nchannels):
                val = raw_ints[i] / 32768.0
                samples.append(val)
        elif sampwidth == 1:
            # 8-bit unsigned
            fmt = f"<{nframes * nchannels}B"
            raw_ints = struct.unpack(fmt, raw_data)
            for i in range(0, len(raw_ints), nchannels):
                val = (raw_ints[i] - 128) / 128.0
                samples.append(val)
        else:
            # basic fallback
            pass
        return samples, framerate
    except Exception:
        return [], 16000

def extract_sherpa_signature(samples: List[float], framerate: int) -> Optional[List[float]]:
    extractor = get_sherpa_extractor()
    if extractor is None:
        return None
    try:
        stream = extractor.create_stream()
        stream.accept_waveform(sample_rate=framerate, waveform=samples)
        stream.input_finished()
        if extractor.is_ready(stream):
            embedding = extractor.compute(stream)
            emb_arr = [float(x) for x in embedding]
            mag = math.sqrt(sum(x * x for x in emb_arr))
            if mag > 0:
                emb_arr = [x / mag for x in emb_arr]
            return emb_arr
    except Exception as e:
        print(f"Warning: Sherpa embedding extraction failed: {e}", file=sys.stderr)
    return None

def extract_voice_signature(samples: List[float], framerate: int) -> Optional[List[float]]:
    # 1. Try Sherpa-ONNX
    if SHERPA_AVAILABLE:
        sig = extract_sherpa_signature(samples, framerate)
        if sig is not None:
            return sig
    # 2. Fallback to Goertzel Spectrogram
    return extract_goertzel_signature(samples, framerate)

def extract_goertzel_signature(samples: List[float], framerate: int) -> Optional[List[float]]:
    """
    Computes a 24-dimensional pitch and spectral envelope signature
    representing the vocal resonance region (80Hz to 3500Hz), capturing F1, F2, and F3 formants.
    Slices and analyzes WAV audio files entirely in-memory for maximum performance.
    """
    if not samples:
        return None

    # Downsample audio to ~8000Hz (Nyquist 4000Hz) to capture formants up to 3500Hz
    if framerate > 8000:
        step = int(round(framerate / 8000.0))
        if step > 1:
            samples = samples[::step]
            framerate = int(round(framerate / step))

    if len(samples) < int(0.100 * framerate):  # Must have at least 100ms of audio
        return None
        
    # Slicing the audio into 100ms windows
    window_size = int(0.100 * framerate)
    
    # Dynamic hop size: cap maximum processed frames to 30 to ensure constant fast speed
    default_hop = int(0.050 * framerate)
    target_frames = 30
    if len(samples) - window_size > default_hop * target_frames:
        hop_size = (len(samples) - window_size) // target_frames
        if hop_size <= 0:
            hop_size = default_hop
    else:
        hop_size = default_hop
    
    # We define 24 frequency bands between 80Hz and 3500Hz (covering F1, F2, and F3)
    num_bands = 24
    bands = []
    start_f = 80.0
    end_f = 3500.0
    factor = math.pow(end_f / start_f, 1.0 / float(num_bands))
    
    current_f = start_f
    for _ in range(num_bands + 1):
        # Translate frequency to DFT bin index: bin = freq * size / rate
        bands.append(int(current_f * window_size / framerate))
        current_f *= factor
        
    # Determine the set of target bins we need
    target_bins = set()
    for b in range(num_bands):
        b_start = bands[b]
        b_end = bands[b+1]
        if b_end == b_start:
            b_end = b_start + 1
        for bin_idx in range(b_start, b_end):
            target_bins.add(bin_idx)

    # Precompute Hann window to avoid math.cos inside the frame loops
    hann_window = [
        0.5 * (1.0 - math.cos(2.0 * math.pi * i / (window_size - 1)))
        for i in range(window_size)
    ]

    # Precompute Goertzel coefficients
    goertzel_coeffs = {
        k: 2.0 * math.cos(2.0 * math.pi * k / window_size)
        for k in target_bins
    }
    
    # Accumulated energy across frames
    band_energies = [0.0] * num_bands
    frame_count = 0
    
    # Process windows
    for start in range(0, len(samples) - window_size, hop_size):
        frame = samples[start:start + window_size]
        
        # Simple VAD (Voice Activity Detection): Skip silent/quiet frames to improve voiceprint purity
        rms = math.sqrt(sum(val * val for val in frame) / len(frame))
        if rms < 0.015:  # Noise gate threshold
            continue
            
        # Apply precomputed Hann window
        hanned_frame = [frame[i] * hann_window[i] for i in range(window_size)]
            
        # Goertzel algorithm for the vocal range bins
        dft_magnitudes = {}
        for k in target_bins:
            coeff = goertzel_coeffs[k]
            s_prev = 0.0
            s_prev2 = 0.0
            for val in hanned_frame:
                s = val + coeff * s_prev - s_prev2
                s_prev2 = s_prev
                s_prev = s
            power = s_prev * s_prev + s_prev2 * s_prev2 - coeff * s_prev * s_prev2
            if power < 0:
                power = 0.0
            dft_magnitudes[k] = math.sqrt(power)
            
        # Accumulate band energies
        for b in range(num_bands):
            energy = 0.0
            bin_start = bands[b]
            bin_end = bands[b+1]
            if bin_end == bin_start:
                bin_end = bin_start + 1
            for bin_idx in range(bin_start, bin_end):
                energy += dft_magnitudes.get(bin_idx, 0.0)
            band_energies[b] += energy / (bin_end - bin_start)
            
        frame_count += 1
        
    # Fallback to process all frames without VAD if the entire segment was quiet
    if frame_count == 0:
        for start in range(0, len(samples) - window_size, hop_size):
            frame = samples[start:start + window_size]
            hanned_frame = [frame[i] * hann_window[i] for i in range(window_size)]
            dft_magnitudes = {}
            for k in target_bins:
                coeff = goertzel_coeffs[k]
                s_prev = 0.0
                s_prev2 = 0.0
                for val in hanned_frame:
                    s = val + coeff * s_prev - s_prev2
                    s_prev2 = s_prev
                    s_prev = s
                power = s_prev * s_prev + s_prev2 * s_prev2 - coeff * s_prev * s_prev2
                if power < 0:
                    power = 0.0
                dft_magnitudes[k] = math.sqrt(power)
            for b in range(num_bands):
                energy = 0.0
                bin_start = bands[b]
                bin_end = bands[b+1]
                if bin_end == bin_start:
                    bin_end = bin_start + 1
                for bin_idx in range(bin_start, bin_end):
                    energy += dft_magnitudes.get(bin_idx, 0.0)
                band_energies[b] += energy / (bin_end - bin_start)
            frame_count += 1
            
    if frame_count == 0:
        return None
        
    # Average across frames
    avg_energies = [e / frame_count for e in band_energies]
    
    # Apply log compression to equalize spectral tilt (like in MFCCs)
    log_energies = [math.log(e + 1e-5) for e in avg_energies]
    
    # Center the log energies (Cepstral Mean Subtraction) to remove volume/gain bias
    mean_log = sum(log_energies) / len(log_energies)
    centered_log = [le - mean_log for le in log_energies]
    
    # Normalize the signature vector to unit length
    magnitude = math.sqrt(sum(le * le for le in centered_log))
    if magnitude == 0:
        return [0.0] * num_bands
    return [le / magnitude for le in centered_log]

def extract_voice_signature_from_file(wav_path: str) -> Optional[List[float]]:
    samples, framerate = read_wav_samples(wav_path)
    if not samples:
        return None
    return extract_voice_signature(samples, framerate)

def cosine_similarity(v1: List[float], v2: List[float]) -> float:
    """Computes the cosine similarity (dot product of normalized vectors) between signatures."""
    if len(v1) != len(v2) or len(v1) == 0:
        return 0.0
    return sum(a * b for a, b in zip(v1, v2))

def learn_speaker(name: str, wav_path: str) -> bool:
    """Extracts signature from WAV and registers it in the Speaker Library."""
    ensure_dirs()
    sig = extract_voice_signature_from_file(wav_path)
    if not sig:
        return False
        
    sig_file = get_speakers_dir() / f"{name}.sig"
    try:
        sig_file.write_text(json.dumps(sig))
        return True
    except OSError:
        return False

def match_voice(wav_path: str) -> Tuple[str, float]:
    """Compares WAV signature against all signatures in the Speaker Library."""
    sig = extract_voice_signature_from_file(wav_path)
    if not sig:
        return ("Unknown Speaker", 0.0)
    return match_voice_signature(sig)

def match_voice_signature(sig: List[float], library: Optional[dict] = None, threshold_override: Optional[float] = None) -> Tuple[str, float]:
    best_match = "Unknown Speaker"
    best_similarity = 0.0
    threshold = threshold_override if threshold_override is not None else get_similarity_threshold()
    
    if library is not None:
        for speaker_name, stored_sig in library.items():
            sim = cosine_similarity(sig, stored_sig)
            if sim > best_similarity:
                best_similarity = sim
                best_match = speaker_name
    else:
        ensure_dirs()
        try:
            speakers_dir = get_speakers_dir()
            for file in speakers_dir.iterdir():
                if file.is_file() and file.suffix.lower() == ".sig":
                    # Skip temporary speakers
                    if file.stem.startswith("Speaker ") and file.stem[8:].isdigit():
                        continue
                    speaker_name = file.stem
                    stored_sig = json.loads(file.read_text())
                    sim = cosine_similarity(sig, stored_sig)
                    if sim > best_similarity:
                        best_similarity = sim
                        best_match = speaker_name
        except Exception:
            pass
        
    if best_similarity >= threshold:
        return (best_match, best_similarity)
    return ("Unknown Speaker", best_similarity)

def diarize_transcript(transcript_path: str, audio_path: str, threshold_override: Optional[float] = None, max_speakers: int = 0) -> None:
    """
    Reads source audio once, slices samples directly in memory based on timestamps in transcript_path,
    matches each slice signature against the Speaker Library, and overwrites the transcript.
    """
    ensure_dirs()
    threshold = threshold_override if threshold_override is not None else get_similarity_threshold()
    trans_file = Path(transcript_path)
    audio_file = Path(audio_path)
    
    if not trans_file.is_file() or not audio_file.is_file():
        print(f"Error: Transcript or audio file not found.", file=sys.stderr)
        sys.exit(1)
        
    try:
        content = trans_file.read_text(encoding="utf-8")
    except OSError as e:
        print(f"Error reading transcript: {e}", file=sys.stderr)
        sys.exit(1)
        
    lines = content.splitlines()
    
    # Parse timestamp lines matching whisper format (supports hh:mm:ss.ms or mm:ss.ms, and both -> and -->)
    import re
    pat = re.compile(
        r"\[(?:(\d{2}):)?(\d{2}):(\d{2})(?:\.(\d{2,3}))?\s*-+>\s*(?:(\d{2}):)?(\d{2}):(\d{2})(?:\.(\d{2,3}))?\]"
    )
    
    diarized_lines = []
    
    print("Speaker Recognition: Loading audio into memory...", file=sys.stderr)
    samples, framerate = read_wav_samples(str(audio_file))
    if not samples:
        print("Error: Could not decode WAV audio. Make sure it is a valid WAV file.", file=sys.stderr)
        sys.exit(1)
        
    print(f"Speaker Recognition: Loaded {len(samples)} samples at {framerate}Hz. Analysing voices...", file=sys.stderr)
    
    # Pre-load all registered speakers to avoid slow disk lookups for every transcript segment
    registered_speakers = {}
    speakers_dir = get_speakers_dir()
    if speakers_dir.is_dir():
        for file in speakers_dir.iterdir():
            if file.is_file() and file.suffix.lower() == ".sig":
                # Clean up generic speaker signatures from previous runs
                if file.stem.startswith("Speaker ") and file.stem[8:].isdigit():
                    try:
                        file.unlink()
                    except Exception:
                        pass
                    continue
                try:
                    registered_speakers[file.stem] = json.loads(file.read_text())
                except Exception:
                    pass
                    
    temp_speakers = {} # Map speaker_temp_name -> signature_vector
    used_speakers = set()
    
    for idx, line in enumerate(lines):
        trimmed = line.strip()
        m = pat.search(trimmed)
        
        # Skip header lines that don't match timestamps
        if not m:
            diarized_lines.append(line)
            continue
            
        # Parse times in seconds
        def to_secs(hrs, mins, secs, ms):
            h = float(hrs) if hrs else 0.0
            m = float(mins)
            s = float(secs)
            milli = float(ms) if ms else 0.0
            factor = 0.01 if ms and len(ms) == 2 else 0.001
            return h * 3600.0 + m * 60.0 + s + milli * factor
            
        start_time = to_secs(m.group(1), m.group(2), m.group(3), m.group(4))
        end_time = to_secs(m.group(5), m.group(6), m.group(7), m.group(8))
        duration = end_time - start_time
        
        if duration <= 0:
            diarized_lines.append(line)
            continue
            
        start_sample = int(start_time * framerate)
        end_sample = int(end_time * framerate)
        
        # Clip segment samples directly from memory
        segment_samples = samples[start_sample:end_sample]
        
        sig = extract_voice_signature(segment_samples, framerate)
        
        speaker = "Unknown Speaker"
        if sig:
            # 1. Match against registered speakers
            speaker, sim = match_voice_signature(sig, registered_speakers, threshold_override=threshold)
            
            if speaker != "Unknown Speaker":
                used_speakers.add(speaker)
            else:
                # 2. If Unknown, check if we can spawn a new speaker
                can_create = (max_speakers == 0) or (len(used_speakers) < max_speakers)
                if can_create:
                    # Create a new Speaker X and register it
                    next_num = len(temp_speakers) + 1
                    speaker = f"Speaker {next_num}"
                    temp_speakers[speaker] = sig
                    registered_speakers[speaker] = sig
                    used_speakers.add(speaker)
                    
                    # Save it in speakers folder immediately as "Speaker X.sig"
                    sig_file = get_speakers_dir() / f"{speaker}.sig"
                    try:
                        sig_file.write_text(json.dumps(sig))
                    except Exception:
                        pass
                else:
                    # Constrained: assign to the best matching speaker among the used speakers
                    best_used_match = "Unknown Speaker"
                    best_used_sim = -1.0
                    for name in used_speakers:
                        if name in registered_speakers:
                            sim_used = cosine_similarity(sig, registered_speakers[name])
                            if sim_used > best_used_sim:
                                best_used_sim = sim_used
                                best_used_match = name
                                
                    if best_used_match != "Unknown Speaker":
                        speaker = best_used_match
                    else:
                        speaker = "Speaker 1"
        
        # Prepend speaker name to transcript line
        timestamp_str = trimmed[trimmed.find("["):trimmed.find("]")+1]
        text_body = trimmed[trimmed.find("]")+1:].strip()
        
        # Strip existing speaker prefix if any
        if text_body.startswith(f"{speaker}:"):
            text_body = text_body[len(speaker)+1:].strip()
        elif ":" in text_body[:20]:
            first_colon = text_body.find(":")
            if first_colon != -1 and first_colon < 15:
                label = text_body[:first_colon]
                if not label.replace(" ", "").isdigit():
                    text_body = text_body[first_colon+1:].strip()
            
        diarized_lines.append(f"{speaker}: {timestamp_str} {text_body}")
            
    # Overwrite the transcript file with diarized output
    output_content = "\n".join(diarized_lines)
    try:
        trans_file.write_text(output_content, encoding="utf-8")
        print("Diarization complete! Speaker annotations added successfully.", file=sys.stderr)
        print(output_content)
    except OSError as e:
        print(f"Error saving diarized transcript: {e}", file=sys.stderr)
        sys.exit(1)

def print_help() -> None:
    print("""
Speaker Recognition CLI
Usage:
  python3 speaker_engine.py --learn <name> <wav_path>
  python3 speaker_engine.py --match <wav_path>
  python3 speaker_engine.py --diarize <transcript_path> <audio_path> [--threshold <val>] [--max-speakers <count>]
    """)

def main() -> None:
    if len(sys.argv) < 2:
        print_help()
        sys.exit(1)
        
    cmd = sys.argv[1]
    if cmd == "--learn" and len(sys.argv) == 4:
        name = sys.argv[2]
        wav = sys.argv[3]
        success = learn_speaker(name, wav)
        if success:
            print(f"Successfully registered speaker: {name}")
        else:
            print(f"Failed to register speaker.")
            sys.exit(1)
            
    elif cmd == "--match" and len(sys.argv) == 3:
        wav = sys.argv[2]
        speaker, sim = match_voice(wav)
        print(f"Speaker: {speaker} (Similarity: {sim:.4f})")
        
    elif cmd == "--diarize" and len(sys.argv) >= 4:
        transcript = sys.argv[2]
        audio = sys.argv[3]
        
        # Parse optional arguments
        threshold_override = None
        max_speakers = 0
        
        args = sys.argv[4:]
        i = 0
        while i < len(args):
            if args[i] == "--threshold" and i + 1 < len(args):
                try:
                    threshold_override = float(args[i+1])
                except ValueError:
                    pass
                i += 2
            elif args[i] == "--max-speakers" and i + 1 < len(args):
                try:
                    max_speakers = int(args[i+1])
                except ValueError:
                    pass
                i += 2
            else:
                i += 1
                
        diarize_transcript(transcript, audio, threshold_override=threshold_override, max_speakers=max_speakers)
        
    else:
        print_help()
        sys.exit(1)

if __name__ == "__main__":
    main()
