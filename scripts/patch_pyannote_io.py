#!/usr/bin/env python3
"""
Patches pyannote/audio/core/io.py to replace torchcodec (requires CUDA 13)
with torchaudio equivalents (works with CUDA 12 stack).

Background:
  - pyannote.audio 4.0.x uses torchcodec for audio I/O
  - torchcodec requires libnvrtc.so.13 (CUDA 13)
  - ctranslate2/faster-whisper requires libcublas.so.12 (CUDA 12)
  - These two CUDA requirements are mutually exclusive
  - Solution: patch pyannote to use torchaudio.load/torchaudio.info instead
  - Reference: https://github.com/bobsummerwill/strato-transcripts/blob/main/WORKAROUNDS.md

Usage:
  python3 patch_pyannote_io.py /path/to/pyannote/audio/core/io.py
"""

import sys

path = sys.argv[1]
with open(path, "r") as f:
    content = f.read()

patches = [
    # __call__: replace AudioDecoder.get_all_samples() with torchaudio.load()
    (
        "        decoder = AudioDecoder(file[\"audio\"])\n"
        "        samples: AudioSamples = decoder.get_all_samples()\n"
        "\n"
        "        waveform = samples.data\n"
        "        sample_rate = samples.sample_rate\n"
        "\n"
        "        # rewind if needed\n"
        "        if isinstance(file[\"audio\"], IOBase):\n"
        "            file[\"audio\"].seek(0)\n"
        "\n"
        "        return self.downmix_and_resample(waveform, sample_rate, channel=channel)",
        "        waveform, sample_rate = torchaudio.load(file[\"audio\"])\n"
        "\n"
        "        # rewind if needed\n"
        "        if isinstance(file[\"audio\"], IOBase):\n"
        "            file[\"audio\"].seek(0)\n"
        "\n"
        "        return self.downmix_and_resample(waveform, sample_rate, channel=channel)",
    ),
    # crop: replace AudioDecoder metadata lookup with torchaudio.info()
    (
        "        decoder = AudioDecoder(file[\"audio\"])\n"
        "\n"
        "        metadata: AudioStreamMetadata = decoder.metadata\n"
        "\n"
        "        sample_rate = metadata.sample_rate\n"
        "        duration = metadata.duration_seconds_from_header\n"
        "        num_samples = self.get_num_samples(\n"
        "            metadata.duration_seconds_from_header, sample_rate\n"
        "        )",
        "        info = torchaudio.info(file[\"audio\"])\n"
        "        sample_rate = info.sample_rate\n"
        "        duration = info.num_frames / sample_rate\n"
        "        num_samples = self.get_num_samples(duration, sample_rate)",
    ),
    # crop: replace AudioDecoder.get_samples_played_in_range() with torchaudio.load() slice
    (
        "        samples: AudioSamples = decoder.get_samples_played_in_range(start, end)\n"
        "        data = samples.data\n"
        "        sample_rate = samples.sample_rate\n"
        "\n"
        "        # rewind if needed (not sure this is needed with torchcodec)\n"
        "        if isinstance(file[\"audio\"], IOBase):\n"
        "            file[\"audio\"].seek(0)",
        "        waveform_full, sample_rate = torchaudio.load(file[\"audio\"])\n"
        "        start_sample = self.get_num_samples(start, sample_rate)\n"
        "        end_sample = self.get_num_samples(end, sample_rate)\n"
        "        data = waveform_full[:, start_sample:end_sample]\n"
        "\n"
        "        # rewind if needed\n"
        "        if isinstance(file[\"audio\"], IOBase):\n"
        "            file[\"audio\"].seek(0)",
    ),
    # get_audio_metadata: replace AudioDecoder with torchaudio.info()
    (
        "    metadata = AudioDecoder(file[\"audio\"]).metadata\n"
        "\n"
        "    # rewind if needed\n"
        "    if isinstance(file[\"audio\"], IOBase):\n"
        "        file[\"audio\"].seek(0)\n"
        "\n"
        "    return metadata",
        "    info = torchaudio.info(file[\"audio\"])\n"
        "\n"
        "    # rewind if needed\n"
        "    if isinstance(file[\"audio\"], IOBase):\n"
        "        file[\"audio\"].seek(0)\n"
        "\n"
        "    return info",
    ),
]

count = 0
for old, new in patches:
    if old in content:
        content = content.replace(old, new, 1)
        count += 1
    else:
        print(f"  WARNING: patch not applied (pattern not found): {old[:60].strip()!r}")

with open(path, "w") as f:
    f.write(content)

print(f"  Applied {count}/{len(patches)} torchcodec→torchaudio patches to io.py")