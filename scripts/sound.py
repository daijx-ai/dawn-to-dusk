import math, struct, sys, wave
rate = 44100
samples = []
for n in range(int(rate * .65)):
    t = n / rate
    value = 0.
    for start, freq in [(0., 880.), (.24, 1108.73)]:
        x = t - start
        if 0 <= x < .32:
            envelope = min(1., x / .015) * math.exp(-x * 13) * max(0., min(1., (.32 - x) / .03))
            value += .10 * envelope * (math.sin(2 * math.pi * freq * x) + .2 * math.sin(2 * math.pi * freq * 2 * x))
    samples.append(struct.pack('<h', int(value * 32767)))
with wave.open(sys.argv[1], 'wb') as sound:
    sound.setnchannels(1); sound.setsampwidth(2); sound.setframerate(rate); sound.writeframes(b''.join(samples))
