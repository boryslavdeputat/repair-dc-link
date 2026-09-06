# Repair-DCLink

**Hub-and-spoke ремонт Active Directory для резервних контролерів, які часто вимкнені або стоять в іншій VLAN.**

Після днів офлайну `repadmin /syncall` падає, RPC 1722 сиплеться на сусідів, які ще вимкнені, ICMP закритий, а Task Scheduler з’їдає `-NoProfile`. Цей набір змушує резервний DC **тягнути реплікацію лише з майстра (PDC)** і ігнорувати решту.

[English](README.md) · [Як запустити](docs/HOW-TO.md) · [Помилки](docs/TROUBLESHOOTING.md)

## Для кого

Невеликі / філіальні ліси, де:

- один DC — PDC / джерело істини
- один або кілька додаткових DC більшість часу вимкнені
- вони можуть бути в іншій VLAN або за фаєрволом без ICMP
- треба, щоб після увімкнення вони самі підтягнулись **через 3 хвилини** і ще щогодини

## Що робить

На **резервному** DC (не на майстрі):

1. Чекає майстра через **nltest або LDAP 389** (ping не обов’язковий)
2. Ставить DNS кожної NIC на IP майстра **в тому ж /24** + `127.0.0.1`
3. Час з ієрархії домену (запас: майстер як NTP, без некоректного `/force`)
4. Лагоднить secure channel до майстра
5. `repadmin /replicate Локальний Майстер <NC> /force` для домену, configuration, schema, DomainDnsZones, ForestDnsZones
6. Пропускає зайві naming context
7. RPC **1722 / 1908 / 1256** до інших резервних DC вважає нормою
8. Ставить задачі SYSTEM через `.cmd` (щоб `schtasks` не парсив `-NoProfile`)

На **майстрі** скрипт одразу виходить. FSMO не хапає. Metadata cleanup не робить.

## Швидкий старт

На резервному DC, як Domain Admin:

```bat
powershell -ExecutionPolicy Bypass -File .\scripts\Install-Repair-DCLink.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Repair-DCLink.ps1
```

Успіх: `ExitCode=0` і біля майстра в `showrepl` є **Last attempt was successful** на сьогодні.

Червоне `dcdiag` лише до іншого резервного DC — норма.

Лог: `C:\Logs\Repair-DCLink.log`  
Статус: `C:\Logs\Repair-DCLink.status.txt`

## Ліцензія

MIT
