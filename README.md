# EC-SI-LMT-DHCP-PRIMARY

Scripts for the primary DHCP server of an Intel lab management tool
(LMT). The tool tracks lab boards and their reservations in IBM Rational
ClearQuest and builds the DHCP configuration from that data.

## What it does

- `dhcp.pl` generates `/etc/dhcpd.conf` from
  `templates/dhcpd.conf` and the board records in ClearQuest, including
  PXE boot details, and keeps a last good copy in `backup`.
- `freeips.pl`, `all.pl` and `problem.pl` report free IP addresses,
  all boards and boards with problems.
- `src/servicescan.cpp` (built as `main`) scans the lab subnets with
  threads; `scan.sh` runs it for each subnet.
- `notifier` scripts email users when reservations begin or end, sync
  reservations and send reports, using the HTML templates in `email`.
- `LMTCommon.pm`, `LMTEmailer.pm` and `LMTShared.pm` hold the shared
  settings, email and ClearQuest connection code.
- `boards` lists the boards for each lab area.

## Tech

- Perl with ClearQuest's CQPerl, MIME::Lite and File::Slurp
- C++ with pthreads for the scanner
- ISC DHCP server

## Setup

The scripts expect to live in `/scripts` and read their settings from
`/scripts/config.ini`. They are usually run from cron. See
[EC-SI-LMT-DHCP-SECONDARY](https://github.com/dmzoneill/EC-SI-LMT-DHCP-SECONDARY)
for the secondary server.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE).
