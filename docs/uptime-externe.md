# Surveillance externe (SCRUM-90)

La stack Loki/Prometheus/Grafana tombe avec la machine qu'elle surveille : elle est
structurellement incapable de signaler sa propre panne. Ces sondes vivent **hors du VPS**,
chez des tiers, et sont donc configurées à la main — il n'y a pas de rôle Ansible.

Ce fichier est la source de vérité de cette configuration : ce qui est surveillé, à quel
seuil, et qui est prévenu.

## 1. UptimeRobot — sondes HTTP

Compte gratuit sur <https://uptimerobot.com> (50 monitors, intervalle 5 min, expiration TLS
incluse). L'intégration Discord est native dès le palier gratuit ; le webhook générique,
lui, est payant et inutile ici.

**Créer l'intégration Discord d'abord**, sinon les monitors sont créés sans destinataire :

1. Dans Discord, salon `#alerting` → *Modifier le salon* → *Intégrations* → *Webhooks* →
   **Nouveau webhook**, le nommer `UptimeRobot`, copier son URL.
2. Dans UptimeRobot : *My Settings* → *Add Alert Contact* → type **Discord** → coller
   l'URL → *Save*.

**Puis créer les monitors** (*Add New Monitor*, type **HTTP(s)**, intervalle **5 minutes**,
cocher l'alert contact Discord) :

| Nom | URL | Attendu |
|---|---|---|
| `greener-api` | `https://api.lucasboillot.fr/health/db` | HTTP 200 |
| `greener-front` | `https://greenhub.lucasboillot.fr` | HTTP 200 |

Sur le monitor `greener-api`, ajouter dans *Advanced* → **Keyword** : `reachable`, en mode
*exists*. Sans ce mot-clé, la sonde se contente du code HTTP.

> **Surveiller `/health/db` et non `/health`.** `/health` répond `{"status":"ok"}` dès
> qu'uvicorn est debout, même Postgres éteint — une sonde dessus reste verte pendant une
> panne de base. `/health/db` répond `{"status":"ok","database":"reachable"}` et touche
> réellement la base. Le ticket rangeait cette amélioration dans « à cadrer avec le
> backend, hors périmètre » : l'endpoint existe déjà, elle est gratuite.

> **`greener-front` sera rouge tant que le front n'est pas déployé.** Vérifié le 22/09/2026 :
> `https://greenhub.lucasboillot.fr` renvoie **404**. Créer le monitor **en pause**, et le
> démarrer au premier déploiement du front — un monitor rouge en permanence apprend à
> l'équipe à ignorer le salon.

**Expiration TLS** : rien à configurer, UptimeRobot prévient automatiquement avant
l'échéance sur un monitor HTTPS. C'est ce qui rend visible un renouvellement ACME cassé, qui
autrement ne se voit que le jour de la panne. Certificat courant : expire le 28/11/2026.

## 2. healthchecks.io — dead man switch des sauvegardes

**À faire seulement quand SCRUM-54 existe.** Le rôle `backups` est encore un stub : aucun
cron ne pingerait l'URL, donc le monitor passerait en alerte dès la première fenêtre
manquée et resterait rouge.

Quand le cron nocturne existera :

1. Compte gratuit sur <https://healthchecks.io>, créer un check `greener-pg-dump`,
   **Period** 1 jour, **Grace** 2 heures (soit la fenêtre de 26 h du ticket).
2. *Integrations* → **Discord** → autoriser sur le salon `#alerting`.
3. Copier l'URL de ping et la mettre au vault — elle est appelable par quiconque la détient,
   donc c'est un secret :

   ```bash
   make vault-edit ENV=production
   # ajouter :  vault_backup_healthcheck_url: "https://hc-ping.com/<uuid>"
   ```

4. Le cron de sauvegarde appelle cette URL **en fin de run et seulement en cas de succès**.

C'est la seule panne interne qu'un service externe peut voir : un backup qui échoue en
silence est indétectable depuis la machine elle-même.

## Ce qui n'est délibérément pas surveillé

- `ai`, `postgres`, `qdrant` : non exposés, et ils ne doivent pas l'être pour être
  surveillés. Leur santé passe par les règles Grafana (SCRUM-131).
- `deploy.lucasboillot.fr` : n'accepte que des POST authentifiés, une sonde GET y recevrait
  un 403 permanent.

## Terminé quand

- [ ] Contact d'alerte Discord créé dans UptimeRobot
- [ ] Monitor `greener-api` actif sur `/health/db` avec le mot-clé `reachable`
- [ ] Monitor `greener-front` créé, **en pause** jusqu'au déploiement du front
- [ ] Un test réel : mettre le monitor en pause/reprise, ou couper le backend une minute,
      et vérifier que le message arrive bien dans `#alerting`
- [ ] Ce fichier mis à jour si un seuil ou un destinataire change
