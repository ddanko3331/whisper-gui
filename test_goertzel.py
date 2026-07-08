import math
import time

def original_dft(samples, framerate, window_size, bands, target_bins):
    hanned_frame = []
    for i, val in enumerate(samples):
        hann = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / (window_size - 1)))
        hanned_frame.append(val * hann)
        
    dft_magnitudes = {}
    for k in target_bins:
        real = 0.0
        imag = 0.0
        for n, val in enumerate(hanned_frame):
            angle = 2.0 * math.pi * k * n / window_size
            real += val * math.cos(angle)
            imag -= val * math.sin(angle)
        dft_magnitudes[k] = math.sqrt(real * real + imag * imag)
    return dft_magnitudes

def optimized_goertzel(samples, framerate, window_size, bands, target_bins):
    # Hann window precomputed
    hann_window = [
        0.5 * (1.0 - math.cos(2.0 * math.pi * i / (window_size - 1)))
        for i in range(window_size)
    ]
    hanned_frame = [samples[i] * hann_window[i] for i in range(window_size)]
    
    # Precompute coefficients
    goertzel_coeffs = {
        k: 2.0 * math.cos(2.0 * math.pi * k / window_size)
        for k in target_bins
    }
    
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
    return dft_magnitudes

def test():
    import random
    framerate = 4000
    window_size = 400
    
    # 16 frequency bands between 80Hz and 1000Hz
    bands = []
    start_f = 80.0
    end_f = 1000.0
    factor = math.pow(end_f / start_f, 1.0 / 16.0)
    current_f = start_f
    for _ in range(17):
        bands.append(int(current_f * window_size / framerate))
        current_f *= factor
        
    target_bins = set()
    for b in range(16):
        b_start = bands[b]
        b_end = bands[b+1]
        if b_end == b_start:
            b_end = b_start + 1
        for bin_idx in range(b_start, b_end):
            target_bins.add(bin_idx)
            
    # Dummy samples
    samples = [random.uniform(-1.0, 1.0) for _ in range(window_size)]
    
    # Run original
    t0 = time.time()
    res_orig = original_dft(samples, framerate, window_size, bands, target_bins)
    t_orig = time.time() - t0
    
    # Run optimized
    t0 = time.time()
    res_opt = optimized_goertzel(samples, framerate, window_size, bands, target_bins)
    t_opt = time.time() - t0
    
    print(f"Original DFT time: {t_orig * 1000:.3f} ms")
    print(f"Goertzel time: {t_opt * 1000:.3f} ms")
    print(f"Speedup: {t_orig / t_opt:.1f}x")
    
    # Verify values
    max_diff = 0.0
    for k in target_bins:
        diff = abs(res_orig[k] - res_opt[k])
        if diff > max_diff:
            max_diff = diff
            
    print(f"Max absolute difference between DFT and Goertzel: {max_diff:.10f}")
    if max_diff < 1e-9:
        print("Success! Mathematically identical results.")
    else:
        print("Failure! Large difference.")

if __name__ == "__main__":
    test()
