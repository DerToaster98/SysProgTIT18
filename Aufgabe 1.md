# Aufgabe 1.1 Boot-Vorgang

Nach Anlegen der Spannung wird der OTP(one-time programmable)-Block gelesen, um zu ermitteln, welcher Boot Mode aktiviert ist. (Beim BCM2835 wird vorher erst der SD-Card boot versucht, danach wird USB Device Boot versucht) Je nach boot mode wird GPIO PIN 48-53(Seite 102 ARM Peripherals Datasheet), primary SD, secondary SD, NAND, SPI oder USB nach der bootcode.bin gesucht. Bei den SD Karten wird nach einem FAIL ein 5 sekündiger Timeout eingeleitet.

Der Bootvorgang läuft in (grob) 5 Stages ab:

Stage 1:
Check Boot Mode + Stage 2 in L2 Cache laden

Stage 2:
Bootcode.bin ausfürhen --> SDRAM aktiviert + Stage 2 in L2 Cache laden

Stage 3:
loader.bin ausführen --> .elf Format bekannt + start.elf wird geladen

Stage 4:
start.elf ausführen --> config.txt, cmdline.txt und bcm2835.dtb werden gelesen (dtb Datei wird in 0x100 geladen und kernel in 0x8000) + kernel.img wird geladen

Stage 5:
kernel.img wird auf den ARM geladen und dort ausgeführt

*Bis Kernel.img auf dem ARM ausgeführt wird, läuft alles auf der GPU!*

Das folgende Diagramm liefert einen detaillierteren Einblick:

![](PI_Boot.png)

# Aufgabe 1.2 Wie wird ein Bare-Metal-System für den Raspberry Pi erzeugt?



# Aufgabe 1.3 Unterschiede zum normalen Betrieb? + Besonderheiten bei der Programmierung

Im Bare Metal Betrieb ist ein uneingeschränkter Zugriff auf alle Register des SoC, wie Timer, GPIO-dataln, etc. möglich. --> keine Relativen Adressen, wie bei Linux.
Speicherbereich muss mit Bedacht zugewiesen werden. --> Überschneidungen führen zu einem System-Interrupt.
Speicherbereich wird von der MMU des OS gespiegelt und als GPIO-Basisadresse verwendet.

Bare Metal Systeme sind, da kein OS im Hintergrund laufen muss, bedeutend schneller. 