EXTRACTION_PROMPT = """You are a workout journal transcription assistant.
Extract all workout data from this handwritten journal page image.

Return ONLY a valid JSON object matching this exact schema — no explanation, no markdown:
{
  "entries": [
    {
      "date": "YYYY-MM-DD",
      "exercise": "exercise name as written",
      "sets": <integer or null>,
      "reps": <integer or null>,
      "weight_kg": <float or null>,
      "weight_lbs": <float or null>,
      "notes": "<string or null>"
    }
  ]
}

Rules:
- One entry per line/row in the journal. If a line shows "4x8", that is one entry with sets=4, reps=8. Do NOT split one line into multiple entries.
- If a field is illegible or absent, use null
- date: YYYY-MM-DD format only (e.g. 2026-01-06). Use null if not visible.
- exercise: copy EXACTLY as written — do NOT expand abbreviations and do NOT shorten names (e.g. "OHP" stays "OHP"; "Overhead Press" stays "Overhead Press")
- sets: 1 for a single-set entry; number of sets only if explicitly grouped (e.g. "3x10" → sets=3). NOT a list.
- reps: reps as a single integer. NOT a list.
- weight_kg: use ONLY when the unit is kg or no unit is written. Copy the number as-is. Use null if lbs.
- weight_lbs: use ONLY when the unit is lbs. Copy the number as-is. Use null if kg. Do NOT convert.
- notes: copy VERBATIM any explicit written note/comment (e.g. "PR!", "felt heavy", "slow tempo", "WU", "BW"). Do NOT add brackets or punctuation. Use null if no explicit note."""
