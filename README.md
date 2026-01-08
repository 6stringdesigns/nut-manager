# NUT UPS Manager Script

Script to run as a service using NUT to monitor UPS status and manage client machines.  
Utilizing Wake on LAN, Wake on AC Power Restore and SSH for shutdowns and startups.

## Features

- Poll UPS status at regular intervals.
- On power loss, run systems on battery for 60 seconds, then shutdown clients if still on battery.
- After clients are down, monitor UPS battery level and shut down UPS if battery below certain level.
- On power restore, wait for stability (90% battery charge and 10min stable power), then wake clients via Wake on LAN.

This is meant to be ran on its own device that is plugged into the UPS, but doesn't shut down unless the UPS does.  


## Requirments

- Network UPS Tools installed on the same machine this script will run on. https://networkupstools.org/
- UPS that works with NUT. Offical list: https://networkupstools.org/stable-hcl.html
- `ups.conf` configured properly for your UPS driver: https://networkupstools.org/docs/man/ups.conf.html
