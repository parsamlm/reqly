# Security

## Reporting a problem

Please don't report a security problem in a public issue. Report it privately on GitHub instead: on the repository's [Security tab](https://github.com/parsamlm/reqly/security), choose **Report a vulnerability**. Only the maintainer sees the report.

Say what the problem is, which versions of Reqly and of macOS or Windows it affects, and how to make it happen. Reqly is maintained by one person, who answers as soon as possible. Once it's fixed, a release carries the fix, and its advisory can credit you if you'd like.

## Supported versions

Security fixes go into the newest release of each app: Reqly for Mac's, and Reqly for Windows', beta or not. Both apps update themselves, so updating is the fix.

## What matters most

Reqly sits in the middle of your traffic, so these matter most:

- The private key of Reqly's root certificate, which each copy makes for itself and keeps on your computer, leaking or being usable by another app.
- Your traffic, sessions, rules or settings reaching anyone other than you.
- A script, rule or session file from someone else doing more than it should. Scripts can't reach your files or the network.
- Your proxy settings left pointing at Reqly after it stops.
- An update installing something that wasn't a Reqly release.
- On the Mac, Reqly's helper acting for a program other than Reqly.

Decrypting HTTPS for the hosts you choose, with a certificate you trusted, is what Reqly is for, and isn't a vulnerability.
