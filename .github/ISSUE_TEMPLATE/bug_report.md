---
name: Something doesn't work
about: A video that won't play, a device that isn't found, or anything else that misbehaves
labels: bug
---

**What happened**

**What you expected**

**The Mac**
- Apple silicon or Intel:
- macOS version:
- Driftcast version (About Driftcast):

**The device**
- Chromecast model, Apple TV, or TV make and model:
- Connected by Wi-Fi or Ethernet:

**The file**
Right-click the video, choose Media Info…, and paste the Video, Audio and "On …" lines here.

**Log**
Run this in Terminal, reproduce the problem, then paste what it printed (it lists the requests
the device made and the player's events; it contains file names and home-network addresses,
nothing else):

```
/usr/bin/log stream --style compact --level info --predicate 'subsystem == "com.leechsoftware.driftcast"'
```
