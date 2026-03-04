package s;

import static data.sounds.S_sfx;
import data.sounds.sfxenum_t;
import doom.DoomMain;
import java.util.HashMap;
import java.util.logging.Level;
import java.util.logging.Logger;
import mochadoom.Loggers;

/**
 * WebAudioSoundDriver — SFX driver for WASM/Emscripten environments.
 *
 * Replicates the ClassicDoomSoundDriver mixing algorithm (8-channel, 8-bit mono
 * → 16-bit signed big-endian stereo) but outputs via a JNI native method that
 * copies PCM data to a shared ring buffer readable from JavaScript.
 *
 * The browser polls the ring buffer and plays audio chunks via Web Audio API
 * (AudioBufferSourceNode at 22050 Hz).
 *
 * No SourceDataLine, no MixServer thread, no Semaphores.
 */
public class WebAudioSoundDriver extends AbstractSoundDriver {

    private static final Logger LOGGER = Loggers.getLogger(WebAudioSoundDriver.class.getName());

    /** Channel step amount (16.16 fixed-point for pitch). */
    protected final int[] channelstep;

    /** Fractional remainder of last step (0.16 fixed-point). */
    protected final int[] channelstepremainder;

    /** Raw 8-bit mono sound data per channel. */
    protected byte[][] channels;

    /** Current read position in each channel's data. */
    protected int[] p_channels;

    /** End position for each channel's data. */
    protected int[] channelsend;

    /** Left/right volume lookup tables per channel. */
    protected final int[][] channelleftvol_lookup, channelrightvol_lookup;

    /** True if any channel was mixed this frame. */
    protected volatile boolean mixed = false;

    protected HashMap<Integer, byte[]> cachedSounds = new HashMap<>();

    /**
     * Native method: copies mixed PCM data to Emscripten shared heap ring buffer.
     * Registered via JNI RegisterNatives in jvm-main.c.
     */
    private static native void nativeSubmitAudio(byte[] pcmData, int length);

    public WebAudioSoundDriver(DoomMain<?, ?> DM, int numChannels) {
        super(DM, numChannels);
        channelleftvol_lookup = new int[numChannels][];
        channelrightvol_lookup = new int[numChannels][];
        channelstep = new int[numChannels];
        channelstepremainder = new int[numChannels];
        channels = new byte[numChannels][];
        p_channels = new int[numChannels];
        channelsend = new int[numChannels];
        mixbuffer = new byte[MIXBUFFERSIZE];
    }

    @Override
    public boolean InitSound() {
        LOGGER.log(Level.INFO, "WebAudioSoundDriver: InitSound");

        // Pre-cache all sound data in 8-bit format
        super.initSound8();
        LOGGER.log(Level.INFO, "WebAudioSoundDriver: pre-cached all sound data");

        // Initialize mixbuffer
        initMixBuffer();

        LOGGER.log(Level.INFO, "WebAudioSoundDriver: sound module ready");
        return true;
    }

    @Override
    public void SetChannels(int numChannels) {
        for (int i = 0; i < this.numChannels; i++) {
            channels[i] = null;
        }
        generateStepTable(128);
        generateVolumeLUT();
    }

    /**
     * Core mixing loop — identical to ClassicDoomSoundDriver.
     * Mixes 8 channels of 8-bit unsigned mono into 16-bit signed big-endian stereo.
     */
    @Override
    public void UpdateSound() {
        mixed = false;

        int sample = 0;
        int dl;
        int dr;
        int leftout;
        int rightout;
        int leftend;
        int step;
        int chan;

        leftout = 0;
        rightout = 2;
        step = 4;
        leftend = SAMPLECOUNT * step;

        for (chan = 0; chan < numChannels; chan++) {
            if (channels[chan] != null) {
                mixed = true;
            }
        }

        while (leftout < leftend) {
            dl = 0;
            dr = 0;

            for (chan = 0; chan < numChannels; chan++) {
                if (channels[chan] != null) {
                    int channel_pointer = p_channels[chan];

                    sample = 0x00FF & channels[chan][channel_pointer];

                    dl += channelleftvol_lookup[chan][sample];
                    dr += channelrightvol_lookup[chan][sample];

                    channelstepremainder[chan] += channelstep[chan];
                    channel_pointer += channelstepremainder[chan] >> 16;
                    channelstepremainder[chan] &= 0xFFFF;

                    if (channel_pointer >= channelsend[chan]) {
                        channels[chan] = null;
                        channel_pointer = 0;
                    }

                    p_channels[chan] = channel_pointer;
                }
            }

            if (dl > 0x7fff) {
                dl = 0x7fff;
            } else if (dl < -0x8000) {
                dl = -0x8000;
            }
            mixbuffer[leftout] = (byte) ((dl & 0xFF00) >>> 8);
            mixbuffer[leftout + 1] = (byte) (dl & 0x00FF);

            if (dr > 0x7fff) {
                dr = 0x7fff;
            } else if (dr < -0x8000) {
                dr = -0x8000;
            }
            mixbuffer[rightout] = (byte) ((dr & 0xFF00) >>> 8);
            mixbuffer[rightout + 1] = (byte) (dr & 0x00FF);

            leftout += 4;
            rightout += 4;
        }
    }

    @Override
    public void SubmitSound() {
        if (mixed) {
            try {
                nativeSubmitAudio(mixbuffer, MIXBUFFERSIZE);
            } catch (UnsatisfiedLinkError e) {
                // Native method not registered yet — silently skip
            }
        }
    }

    @Override
    protected int addsfx(int sfxid, int volume, int step, int seperation) {
        int i;
        int rc = -1;

        int oldest = DM.gametic;
        int oldestnum = 0;
        int slot;

        int rightvol;
        int leftvol;

        int broken = -1;

        // Chainsaw/pistol: play only one at a time
        if ((sfxid >= sfxenum_t.sfx_sawup.ordinal()
                && sfxid <= sfxenum_t.sfx_sawhit.ordinal())
                || sfxid == sfxenum_t.sfx_stnmov.ordinal()
                || sfxid == sfxenum_t.sfx_pistol.ordinal()) {
            for (i = 0; i < numChannels; i++) {
                if ((channels[i] != null) && (channelids[i] == sfxid)) {
                    this.p_channels[i] = 0;
                    this.channels[i] = null;
                    broken = i;
                    break;
                }
            }
        }

        // Find oldest channel
        if (broken >= 0) {
            i = broken;
            oldestnum = broken;
        } else {
            for (i = 0; (i < numChannels) && (channels[i] != null); i++) {
                if (channelstart[i] < oldest) {
                    oldestnum = i;
                }
            }
        }

        oldest = channelstart[oldestnum];

        if (i == numChannels) {
            slot = oldestnum;
        } else {
            slot = i;
        }

        // Set up channel
        channels[slot] = S_sfx[sfxid].data;
        p_channels[slot] = 0;
        channelsend[slot] = lengths[sfxid];

        if (handlenums == 0) {
            handlenums = 100;
        }
        channelhandles[slot] = rc = handlenums--;

        channelstep[slot] = step;
        channelstepremainder[slot] = 0;
        channelstart[slot] = DM.gametic;

        // Separation → stereo volume
        seperation += 1;
        leftvol = volume - ((volume * seperation * seperation) >> 16);
        seperation = seperation - 257;
        rightvol = volume - ((volume * seperation * seperation) >> 16);

        if (rightvol < 0) rightvol = 0;
        if (rightvol > 127) rightvol = 127;
        if (leftvol < 0) leftvol = 0;
        if (leftvol > 127) leftvol = 127;

        channelleftvol_lookup[slot] = vol_lookup[leftvol];
        channelrightvol_lookup[slot] = vol_lookup[rightvol];

        channelids[slot] = sfxid;

        return rc;
    }

    @Override
    public void ShutdownSound() {
        // Nothing to shut down — no audio device, no threads
    }

    @Override
    public boolean SoundIsPlaying(int handle) {
        int c = getChannelFromHandle(handle);
        return (c != -2 && channels[c] == null);
    }

    @Override
    public void StopSound(int handle) {
        int hnd = getChannelFromHandle(handle);
        if (hnd >= 0) {
            channels[hnd] = null;
            p_channels[hnd] = 0;
            this.channelhandles[hnd] = IDLE_HANDLE;
        }
    }

    @Override
    public void UpdateSoundParams(int handle, int vol, int sep, int pitch) {
        int chan = this.getChannelFromHandle(handle);
        if (chan < 0) return;

        int leftvol = vol - ((vol * sep * sep) >> 16);
        sep = sep - 257;
        int rightvol = vol - ((vol * sep * sep) >> 16);

        if (rightvol < 0) rightvol = 0;
        if (rightvol > 127) rightvol = 127;
        if (leftvol < 0) leftvol = 0;
        if (leftvol > 127) leftvol = 127;

        channelleftvol_lookup[chan] = vol_lookup[leftvol];
        channelrightvol_lookup[chan] = vol_lookup[rightvol];

        this.channelstep[chan] = steptable[pitch];
        channelsend[chan] = this.lengths[this.channelids[chan]];
    }

    protected int getChannelFromHandle(int handle) {
        for (int i = 0; i < numChannels; i++) {
            if (channelhandles[i] == handle) {
                return i;
            }
        }
        return BUSY_HANDLE;
    }
}
