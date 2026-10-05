package kaya

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestTimecodeDoor(t *testing.T) {
	rate := TimecodeRate{Numerator: 30000, Denominator: 1001, Drop: true}
	if got := FormatTimecode(1800, rate); got != "00:01:00;02" {
		t.Fatalf("drop minute = %q", got)
	}
	if got, ok := ParseTimecode("00:01:00;02", rate); !ok || got != 1800 {
		t.Fatalf("parse = %d, %v", got, ok)
	}
	for _, text := range []string{"00:01:00;00", "00:01:00;02\x00junk", "00:01:00;30"} {
		if _, ok := ParseTimecode(text, rate); ok {
			t.Fatalf("accepted %q", text)
		}
	}
	if got := Timecode(TimecodeRate{Numerator: -25, Denominator: 1}).wire(); got != "timecode:-25/1:ndf" {
		t.Fatalf("invalid rate changed: %q", got)
	}
	if got := Number().wire(); got != "number" {
		t.Fatalf("number format = %q", got)
	}
}

func TestTimecodeRateRefusedBeforeNUL(t *testing.T) {
	if trap, _ := LookupEnv("KAYA_TIMECODE_RATE_REFUSAL"); trap == "1" {
		ParseTimecode("00:00:00:00\x00junk", TimecodeRate{Numerator: 25, Denominator: 0})
		t.Fatal("invalid rate was hidden by NUL text")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestTimecodeRateRefusedBeforeNUL$")
	cmd.Env = append(cmd.Environ(), "KAYA_TIMECODE_RATE_REFUSAL=1")
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("rate refusal timed out: %v", ctx.Err())
	}
	if err == nil || !strings.Contains(string(out), "format timecode rate 25/0") {
		t.Fatalf("invalid rate must fault before NUL refusal: err=%v, output=%s", err, out)
	}
}
