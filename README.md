# Claude Code Statusline

Statusline 3 lignes pour [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI — modele, git, contexte, cout session, quotas 5h/7j (+ quota Fable 7j dedie) avec calcul de cout reel depuis les logs JSONL. Sur un serveur, la première ligne dit où l'on est et comment va la machine.

> **Branche `serveur`** : version durcie, avec le [mode serveur](#mode-serveur) et son installeur (`serveur/installer.sh`). La statusline de poste, celle qu'installe `npx github:jeremywtp/statusline-claude-code`, reste sur la branche `main`.

## Preview

```
Opus 5.5 ▌▌▌▌▌ │ my-project │ v2.1.280 ●
██████░░░░░░░░░ 40% │ $1.24 │ 3m 22s │ * main +2 ~1 ?3 ↑3 ↓1
5h ▰▰▰▰▱▱▱▱▱▱ 40% 3h12m $18.50 │ 7j ▰▱▱▱▱▱▱▱▱▱ 18% 5j 8h $142.50 │ Fable 14%
```

Sur un serveur (voir [Mode serveur](#mode-serveur)) :

```
 WEB-PROD  │ CPU 6% │ RAM 41% │ disque 78% · data 41%
Opus 5.5 ▌▌▌▌▌ │ …/apps/mon-site.fr │ v2.1.323 ●
██████░░░░░░░░░ 40% │ 7j ▰▱▱▱▱▱▱▱▱▱ 18% 5j 8h │ Fable 14% │ * main ~2 │ pm2 ● en ligne ↺4
```

## Fonctionnalites

**Ligne 1 — Identite & Statut**
- Nom du modele avec couleur (Fable / Mythos 5, 5.1 et 5.2 = or/ambre, Opus = magenta, Sonnet = bleu, Haiku = cyan)
- Indicateur **⚡** (jaune) si le fast mode est actif (champ `.fast_mode` du JSON stdin, repli `fastMode` de `settings.json`)
- Indicateur **effort level** en barres verticales (lu en direct depuis le champ `.effort.level` du JSON stdin, fallback `<local-command-stdout>` du JSONL), adapte au modele. Toutes les graduations sont des `▌` : celles atteintes prennent la couleur du niveau, les suivantes restent grises (`DIM`)
  - **Sonnet 4.6 & autres** (4 graduations) : low (1, cyan) → medium (2, jaune) → high (3, rouge) → max (4, magenta). `xhigh` retombe sur high ; **ultracode** affiche 4 graduations + `✦`
  - **Fable / Mythos (5, 5.1 et 5.2), Opus, Sonnet 5 / 5.5 & Haiku 5.5** (5 graduations) : insere xhigh (4, orange) entre high et max (xhigh existe a partir d'Opus 4.7, sur Fable / Mythos, sur Sonnet 5 / 5.5 et sur Haiku 5.5) ; le mode **ultracode** s'affiche `▌▌▌▌▌ ✦` en magenta vif
  - **Haiku 4.5 et anterieurs** : pas d'indicateur (ces modeles n'ont pas de niveau d'effort). **Haiku 5.5** est le premier Haiku a effort (low → max, xhigh compris, defaut `medium`) et suit l'echelle 5 graduations ci-dessus
  - Niveau absent, `default` ou inconnu → rendu comme `medium`
- Nom du sub-agent (si applicable)
- Mode vim (`[N]`/`[I]`)
- Nom du projet courant
- Version de Claude Code
- Indicateur **status Claude** via [status.claude.com](https://status.claude.com) (API `summary.json`, cache 60s) :
  - `●` vert — Operational
  - `●` jaune — Degraded Performance
  - `●` orange — Partial Outage
  - `●` rouge — Major Outage
  - `●` bleu — Maintenance

**Ligne 2 — Contexte, Session & Git**
- Barre de progression du contexte avec seuils de couleur (vert < 70%, jaune < 90%, rouge >= 90%)
- Cout de la session courante (USD)
- Duree de la session
- Branche git avec fichiers staged (`+`), modifies (`~`), untracked (`?`), commits non pousses (`↑` cyan) et commits remote non recuperes (`↓` jaune)
- **Auto-fetch en background** : si l'upstream est tracke et que le dernier fetch date de plus de 5 min, lance `git fetch --quiet --no-tags` en detache (`& disown` — le statusline tourne sous bash, contrairement au hook `UserPromptSubmit` decrit plus bas qui doit rester POSIX) pour que `↓N` reste a jour sans bloquer le rendu (au plus un fetch toutes les 5 min par session, les trois descripteurs fermés ; **jamais en mode serveur**)

**Ligne 3 — Quotas d'utilisation**
- Quota 5 heures : mini-barre + pourcentage + timer avant reset + **cout 5h**. Le segment est **masque** (separateur compris) tant que l'API ne rapporte pas de fenetre 5h en cours : `five_hour: null` (observe depuis le 31/10/2026 sur Max 20x, ou seules les limites hebdo `weekly_all` / `weekly_scoped` restent exposees) ou `resets_at` deja passe — meme regle que Claude Code, qui documente ce champ comme optionnel. Il revient de lui-meme des que l'API rapporte une fenetre
- Quota 7 jours : mini-barre + pourcentage + timer avant reset + **cout hebdo reel** (`seven_day`, sinon l'entree `weekly_all` de `limits[]`)
- **Quota Fable 7j** : pourcentage seul, label or/ambre — Fable (5, 5.1 et 5.2) a sa propre limite hebdo, exposee par l'API dans `limits[]` (premiere entree `weekly_scoped` dont `scope.model.display_name` **contient** `fable` — test regex insensible a la casse, pas une egalite stricte, donc valable quelle que soit la version : verifie en session Fable 5.2 le 10/11/2026). Le segment est masque si le compte n'a pas de limite dediee
- Pourcentages et fins de fenêtre : ceux que Claude Code transmet au script (`rate_limits`), donc ceux du compte réellement utilisé par la session ; à défaut, ceux de l'API OAuth Anthropic, interrogée **en arrière-plan** (cache 300s, backoff 429 10min, un seul rafraîchissement à la fois). Le quota Fable vient de l'API. Une reponse est acceptee des qu'elle est un objet JSON portant `five_hour`, `seven_day` ou `limits` (meme a `null`) : exiger un `five_hour` non null figeait les pourcentages sur le dernier cache quand le compte n'a pas de fenetre 5h

## Mode serveur

Un fichier `/etc/claude-statusline.conf` (root) fait d'une machine un serveur. La statusline tient alors sur trois lignes : la ligne du serveur en tête, la ligne du modèle avec le dossier courant et son parent (`…/apps/mon-site.fr`), puis une seule ligne qui regroupe le contexte, les quotas, la branche git et l'état PM2 de l'app dans laquelle on se trouve. Quand la place manque sur cette dernière, la mini-barre du quota raccourcit puis s'efface, la barre de contexte raccourcit, puis les segments partent du moins utile au plus utile ; le contexte et le quota 7 j restent toujours.

Sur un serveur elle est **allégée** : ce qui ne sert pas pendant une maintenance n'est pas affiché.

| Sur un serveur | Pourquoi | Réglage |
|---|---|---|
| Pas de montants en dollars (session, 5 h, 7 j) | Sur un abonnement, ces montants ne correspondent à aucune facture. Du même coup, aucun JSONL n'est lu | `COUTS=1` pour les afficher |
| Pas d'usage 5 h | Le quota 7 j et le quota Fable suffisent | — |
| Pas de durée de session | Aucune décision n'en dépend | — |
| Pas de `git fetch` automatique | Écrit dans `.git`, prend des verrous, utilise les identifiants du serveur | `AUTOFETCH=1` pour l'activer |
| Quota Fable, version de Claude Code et point de statut : **gardés** | Le quota Fable passe par l'API des quotas (jeton donné à `curl` par son entrée standard), le point de statut par status.claude.com | `QUOTA_API=0` et `STATUT_CLAUDE=0` pour couper ces deux appels |

Tant qu'aucun quota n'est connu (ni transmis par Claude Code, ni reçu de l'API), la ligne des quotas n'est pas affichée.

```
SERVEUR=WEB-PROD
NIVEAU=critique
DISQUES=/ /mnt/data
```

| Clé | Rôle |
|---|---|
| `SERVEUR` | Nom affiché dans le badge. Sa présence active le mode serveur |
| `NIVEAU` | Couleur du badge : `critique` rouge, `prod` orange, `outils` bleu, `secours` gris |
| `DISQUES` | Points de montage surveillés, séparés par des espaces |
| `COUTS`, `AUTOFETCH` | `0` ou `1` : montants en dollars, fetch automatique (à `0` sur un serveur, à `1` sur un poste) |
| `QUOTA_API`, `STATUT_CLAUDE` | `0` ou `1` : API des quotas (quota Fable), point de statut (à `1` partout) |

Le fichier est **lu, jamais exécuté** : chaque valeur doit tenir en 60 caractères ASCII sans caractère de commande, sinon elle est ignorée. Quand `/etc/claude-statusline.conf` existe, lui seul compte ; sans lui, `~/.config/claude-statusline.conf` permet les mêmes réglages sur un poste.

La ligne du serveur montre toujours le badge, le processeur, la mémoire prise et les disques. Le processeur est la part du temps où les cœurs ont travaillé depuis l'affichage précédent (compteurs de `/proc/stat`, comme `htop` ; il apparaît au deuxième affichage, le premier servant de point de départ). Quand la mémoire dépasse 80 %, le nom et le poids du plus gros consommateur suivent (`RAM 95% · mon-site.fr 6,1 Go`) : le nom de l'app si le programme tourne depuis `/var/www/apps/<app>`, sinon celui du programme, jamais ses arguments. Le reste n'apparaît que s'il y a quelque chose à dire : pression mémoire (PSI, à partir de 5 %), apps PM2 à l'arrêt ou en erreur, builds Next en cours, autre session Claude ouverte sur la machine. Le swap n'est pas affiché : plein en permanence sur certains serveurs sans que rien n'attende de mémoire, il ne dit rien. Ce qui demande de l'attention passe en jaune puis en rouge, et c'est ce qui reste affiché quand la place manque ; les alertes qui ne tiennent pas sont comptées en fin de ligne (`+2 alertes`). Redémarrage demandé et mises à jour en attente ne sont pas affichés : sur un parc de serveurs ils sont presque toujours vrais, donc muets.

Deux variables d'environnement, si le lanceur de la session les pose : `STATUSLINE_OPERATOR` (nom de l'opérateur, affiché après le badge) et `STATUSLINE_ACCOUNT` (compte affiché en fin de ligne des quotas). Elles sont validées (`[A-Za-z0-9._-]`, 24 caractères) avant affichage.

### Installer sur un serveur

Pas de `npx` sur un serveur : `serveur/installer.sh` pose un script dont l'empreinte a été vérifiée, sans rien télécharger.

```bash
sha256sum statusline.sh                       # empreinte du script relu
sudo bash serveur/installer.sh --source statusline.sh --empreinte <sha256> \
  --serveur WEB-PROD --niveau critique --disques "/ /mnt/data"            # montre le plan
sudo bash serveur/installer.sh … --appliquer                                                          # écrit
```

Il installe `/usr/local/lib/claude-statusline/statusline.sh` (root, 755), `/etc/claude-statusline.conf` (root, 644) et met la statusline en service dans `/etc/claude-code/managed-settings.json` (tous les comptes de la machine ; `--portee compte` pour le seul compte courant), avec `refreshInterval` à 2 s (`--intervalle` pour changer) : le processeur et la mémoire bougent à l'écran comme dans `htop`, voir [Rafraîchissement en direct](#rafraîchissement-en-direct-de-la-ligne-du-serveur). Les autres clés des réglages sont conservées, chaque fichier remplacé est copié à côté avec la date, `--retirer` défait tout.

## Largeur du terminal

Claude Code donne la largeur du terminal dans `COLUMNS`. Chaque ligne s'y adapte sans jamais couper un segment au milieu : les segments les moins importants partent en premier (version, durée, coût de session, rôle du serveur), puis les mini-barres de quota passent de 10 à 5 blocs, puis les coûts et les barres s'effacent. Sans `COLUMNS`, le rendu est complet.

## Sécurité

- **Jeton OAuth** : donné à `curl` par son entrée standard (`-K -`), jamais en argument (une ligne de commande se lit par tous les comptes d'une machine). Retiré de l'environnement dès le début du script : ni `git`, ni `jq`, ni `pm2` n'en héritent. Jamais écrit sur disque.
- **Affichage** : la sortie s'écrit avec `printf '%s'`, qui n'interprète rien, et tout texte venu de l'extérieur (dossier, branche, modèle, agent, session, cache, réglage) est débarrassé de ses caractères de contrôle. Un dossier nommé `x\033[41m…` s'affiche tel quel.
- **Calcul** : aucun `eval`. Toute valeur passe par une validation de nombre avant d'entrer dans une opération arithmétique (bash évalue `a[$(commande)]` comme une expression).
- **Cache** : `~/.cache/claude-statusline/<profil>/`, dossier 700 et fichiers 600 quel que soit le masque de la session, refusé si c'est un lien ou s'il appartient à un autre compte. Plus rien dans `/tmp`. Son contenu reste relu comme une donnée douteuse.
- **Git** : un seul `git status --porcelain=v2`, avec `--no-optional-locks` (n'écrit jamais l'index) et `-c core.fsmonitor=false` (une commande déclarée par le dépôt n'est pas lancée). Pas de `fetch` en mode serveur.
- **PM2** : interrogé seulement si le démon du compte tourne déjà. La sortie de `pm2 jlist` (qui porte l'environnement des apps) ne quitte pas le tube : seuls le dossier, le nom, l'état et le nombre de redémarrages sont gardés.
- **Temps** : le rendu ne fait aucun appel réseau et ne lit aucun JSONL. API des quotas, statut de Claude, coûts et état du serveur sont rafraîchis par un processus détaché, un seul à la fois.

## Calcul des couts

Les couts (5h et hebdo) sont calcules localement a partir des fichiers JSONL de conversation (`~/.claude/projects/**/*.jsonl`), en utilisant les prix officiels Anthropic. Le scan est limite aux fichiers modifies dans les 7 derniers jours (`find -mtime -7`) et ne retient que les messages `type == "assistant"` posterieurs au debut de la fenetre hebdo.

Chaque JSONL donne un **extrait** gardé dans le cache et refait seulement quand le JSONL a changé : après le premier passage, seules les sessions en cours sont relues (mesuré sur 226 fichiers et 2,6 Go : 12 s de rendu bloqué avec l'ancienne lecture complète, 4 s en arrière-plan au premier passage, 0,6 s ensuite). La lecture se fait ligne par ligne : une ligne tronquée est ignorée au lieu d'arrêter la lecture des fichiers suivants.

Les messages sont **dedupliques par `requestId`** (`group_by(.reqId) | map(last)`) : le streaming ecrit plusieurs lignes JSONL pour une meme requete, seule la derniere porte les compteurs de tokens definitifs.

**Fallback cote serveur** : quand Fable (5 / 5.1 / 5.2), Opus 5.5, Opus 5 ou Sonnet 5.5 refuse une requete et qu'elle est rejouee sur un modele de repli (table de Claude Code v2.1.322, inchangee depuis la v2.1.284 — Fable et Opus 5.5 : bio → Opus 5, cyber → Opus 4.8, frontier_llm → Opus 5 ; Opus 5 : cyber → Opus 4.8 seulement ; Sonnet 5.5 : cyber et frontier_llm → Sonnet 5 ; les autres categories n'ont pas de repli, et Haiku 5.5 comme Mythos 5.1 / 5.2 n'ont aucun repli), le JSONL porte un tableau `usage.iterations` avec une entree par tentative et son propre `model`. C'est le registre officiel de facturation : chaque tentative ayant produit de l'output est facturee **au tarif de son modele et a sa vitesse** (la partie deja streamee par le modele qui refuse a son propre tarif, la suite au tarif du modele de repli ; le `speed` d'une entree prime sur celui de la requete, un repli pouvant le surcharger) ; une tentative refusee avant le premier token n'est pas facturee. Le script deduplique d'abord par `requestId` (derniere ligne JSONL = compteurs definitifs), puis deplie une tentative facturable par entree de `iterations` au lieu de se fier au `model` de premier niveau, qui ne designe que le modele ayant servi la reponse. Un refus sec (`stop_reason: refusal` sans output, hors fallback) n'est pas facture non plus : sa liste de tentatives est vide, ce qui neutralise aussi les lignes de streaming intermediaires de la requete.

**Web search** : les recherches web cote serveur (`usage.server_tool_use.web_search_requests`) sont facturees $10 / 1 000 requetes quel que soit le modele, en plus des tokens (rattachees a la derniere tentative, celle qui a servi la reponse) ; web fetch est gratuit.

Le cout 5h est filtre depuis les memes donnees JSONL que le cout hebdo, en utilisant la fenetre `resets_at - 5h` de l'API. Sans fenetre rapportee par l'API (ou si la fenetre en cache est deja echue, cas ou tout l'hebdo tomberait dans le bloc 5h), repli sur une fenetre glissante de 5h depuis maintenant ; le cout n'est alors plus affiche puisque le segment 5h est masque.

### Prix (USD / MTok) — Novembre 2026

| Modele | Input | Output | Cache 5min write | Cache 1h write | Cache read |
|---|---|---|---|---|---|
| **Fable 5.2 / Mythos 5.2** (flagship, sorti le 09/11/26) | $8 | $40 | $10 | $16 | **$0.20** |
| **Fable 5.2 / Mythos 5.2 Fast** (`speed: fast`) | $16 | $80 | $20 | $32 | **$0.40** |
| **Fable 5.1 / Mythos 5.1** (sorti le 01/09/26) | $10 | $50 | $12.50 | $20 | **$0.25** |
| **Fable 5 / Mythos 5** | $10 | $50 | $12.50 | $20 | $1 |
| **Opus 5.5** (sorti le 22/09/26) | $4 | $20 | $5 | $8 | **$0.20** |
| **Opus 5.5 Fast** (`speed: fast`) | $8 | $40 | $10 | $16 | **$0.40** |
| **Opus 5 / Opus 4.8** | $5 | $25 | $6.25 | $10 | $0.50 |
| **Opus 5 / Opus 4.8 Fast** (`speed: fast`) | $10 | $50 | $12.50 | $20 | $1 |
| **Opus 4.5 / 4.6 / 4.7** | $5 | $25 | $6.25 | $10 | $0.50 |
| **Opus 4.6 / 4.7 Fast** (historique, retire) | $30 | $150 | $37.50 | $60 | $3 |
| **Sonnet 5.5** (sorti le 28/09/26) | $2 | $10 | $2.50 | $4 | **$0.10** |
| **Sonnet 5** | $2 | $10 | $2.50 | $4 | $0.20 |
| **Sonnet 4.6 / 4.5** (et fallback general) | $3 | $15 | $3.75 | $6 | $0.30 |
| **Haiku 5.5** (sorti le 07/10/2026) — prompt <= 100K tokens | $0.10 | $0.50 | $0.125 | $0.20 | $0.01 |
| **Haiku 5.5** — prompt > 100K tokens (tout x5, output compris) | $0.50 | $2.50 | $0.625 | $1 | $0.05 |
| **Haiku 4.5** | $1 | $5 | $1.25 | $2 | $0.10 |
| Opus legacy (4 / 4.1, retires) | $15 | $75 | $18.75 | $30 | $1.50 |

Regle generale des caches : write 5 min = x1.25 du prix input, write 1h = x2, read = x0.1 — **sauf Fable 5.2 / 5.1 et Mythos 5.2 / 5.1 ou le read vaut x0.025** ($0.20 sur 5.2, $0.25 sur 5.1) **et Opus 5.5 / Sonnet 5.5 ou il vaut x0.05** ($0.20 et $0.10). En fast mode, ces multiplicateurs s'appliquent au tarif input fast ; sur Haiku 5.5, au tarif input du palier en vigueur ($0.10 ou $0.50). Verifie le 10/11/2026 sur [platform.claude.com/docs/en/about-claude/pricing](https://platform.claude.com/docs/en/about-claude/pricing) et recoupe avec le catalogue de prix embarque dans Claude Code v2.1.322 (`pricing_tiers`).

> **Fable 5.2** — et **Mythos 5.2** (acces restreint, meme tier et meme tarif) — sorti le 09/11/2026 (connu de Claude Code depuis la v2.1.321 du 09/11/2026, ou il devient la cible de l'alias `fable` ; les choix Fable 5.1 memorises y basculent d'eux-memes sur les plans Pro et Max) : $8/$40 (20 % sous Fable 5.1), caches write $10 / $16, cache read x0.025 ($0.20), batch $4/$20. **Premier Fable a fast mode** : $16/$80 (x2), caches $20 / $32 / $0.40 ; il demande Claude Code v2.1.321+, ne s'active que par un `/fast` lance sur Fable 5.2 et se paie en credits d'usage, hors quota d'abonnement. Contexte 1M au tarif standard, 128K de sortie, thinking adaptatif toujours actif, effort `medium` par defaut dans Claude Code (`high` sur l'API). Ecart mesure contre `cost.total_cost_usd` sur une session reelle standard (4 requetes, $0.8032) : 0 % — avant la branche dediee, le script le facturait au tarif Fable 5 (+36,7 % sur cette session). Le tarif fast vient de la table du binaire Claude Code et de la page de prix : il n'a pas ete mesure en session reelle (facture en credits d'usage).
> **Fable 5.1** — et **Mythos 5.1** (Project Glasswing, meme tier et meme tarif) — sorti le 01/09/2026 : memes $10/$50 et caches write que Fable 5, mais cache read 4x moins cher ($0.25). Sans fast mode. Fable 5.1 et Fable 5 / Mythos 5 (cache read $1) restent servis a leur tarif.
> **Opus 5.5** — sorti le 22/09/2026, modele par defaut de Claude Code : $4/$20 (20 % sous Opus 5), caches write $5 / $8 et cache read x0.05 ($0.20, 60 % sous Opus 5). Fast mode $8/$40 (x2, Claude API uniquement). Contexte 1M au tarif standard. Opus 5 / Opus 4.8 restent servis a $5/$25.
> Fast mode : Fable 5.2 / Mythos 5.2 ($16/$80), Opus 5.5 ($8/$40), Opus 5 et Opus 4.8 ($10/$50 ; celui d'Opus 4.8, deprecie le 30/10/2026, sera retire le 30/11/2026). Opus 4.7 fast ($30/$150) est retire (erreur API desormais, tarif conserve pour les messages historiques) ; Opus 4.6 fast a ete retire le 29/06/2026 (facture au tarif standard depuis, `usage.speed` vaut `standard`) ; le calcul suit le champ `speed` reel de chaque message.
> **Sonnet 5.5** — sorti le 28/09/2026, alias `sonnet` de Claude Code : $2/$10 et caches write $2.50 / $4 comme Sonnet 5, mais **cache read a x0.05 ($0.10)** — au lancement il etait au multiplicateur standard ($0.20), Anthropic l'a baisse le 07/10/2026 ([notes de version](https://platform.claude.com/docs/en/release-notes/overview) : « from $0.20 USD to $0.10 USD per million tokens ») ; la baisse n'a ete integree ici que le 10/11/2026, en recoupant la page de prix avec le catalogue de Claude Code (palier `tier_2_10_cache_read_0_10`). Batch $1/$5, sans fast mode. Contexte 1M au tarif standard, 128K de sortie. Ecart mesure contre `cost.total_cost_usd` de Claude Code sur une session reelle (4 requetes, $0.1547) : 0 %, contre +8,6 % avec l'ancien tarif.
> **Haiku 5.5** — sorti le 07/10/2026 (connu de Claude Code depuis la v2.1.293 du 07/10/2026, ou il devient la cible de l'alias `haiku` sur l'API first-party — donc des sub-agents declares `model: haiku` ; Bedrock / Vertex / Foundry restent sur Haiku 4.5) : premier modele a **tarif par palier de longueur de prompt**. Jusqu'a 100K tokens de prompt : $0.10/$0.50 (10x moins cher que Haiku 4.5), caches $0.125 / $0.20 / $0.01, batch $0.05/$0.25. Au-dela : **tout x5, output compris** : $0.50/$2.50, caches $0.625 / $1 / $0.05, batch $0.25/$1.25. Le prompt compte `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` (5 min et 1h confondus) et bascule quand il depasse **strictement** 100 000, requete par requete (tentative par tentative en cas de fallback) — regle identique a celle de Claude Code (`longPrompt.abovePromptTokens` dans son calcul de `total_cost_usd`). Contexte 1M natif, 128K de sortie, thinking adaptatif toujours actif, effort `medium` par defaut (API et Claude Code), sans fast mode ni repli de refus cote serveur. Ecart mesure contre `cost.total_cost_usd` : 0 % sur deux sessions reelles, l'une sous le palier (5 requetes, $0.0053), l'autre au-dessus (prompt de 268K tokens, $0.2554).
> **Sonnet 5** : le tarif de lancement $2/$10 (annonce comme introductif jusqu'au 31/08/2026) est devenu le tarif definitif — Anthropic a annule la hausse a $3/$15 prevue le 01/09/2026. Sans fast mode.
> Non pris en compte (non calculables ou sans objet depuis les JSONL Claude Code) : remise Batch API (-50 %), multiplicateur data residency x1.1 (`inference_geo: us` — le champ `usage.inference_geo` des JSONL vaut `global` sur les 6 960 lignes de reponse de la semaine controlee le 10/11/2026, cas ou le multiplicateur ne s'applique pas), surcouts fixes du system prompt tool use (deja inclus dans `input_tokens`), prime +10 % des endpoints regionaux Bedrock / Vertex. Le contexte 1M est au tarif standard sur tous les modeles 4.6+ (aucun supplement au-dela de 200K), **a la seule exception de Haiku 5.5** dont le palier > 100K tokens est pris en compte (voir ci-dessus).

#### Matching des modeles

Le tarif est choisi par test successif sur la chaine `.message.model` du JSONL (ou `iterations[].model` en cas de fallback), **premier match gagnant** :

`fable-5-2|mythos-5-2` → `fable-5-1|mythos-5-1` → `fable|mythos` → `opus-5-5` → `opus-5|opus-4-8` → `opus-4-[567]` → `opus-4-[01]($|[-@])|opus-4($|[-@]2025)` (legacy) → `opus` → `haiku-5-5` → `haiku` → `sonnet-5-5` → `sonnet-5` → fallback general.

Six consequences a garder en tete :

- Le fallback general (modele non reconnu) applique le tarif **Sonnet 4.6** ($3/$15).
- `opus-5-5` **doit** rester avant `opus-5|opus-4-8` : la regex `opus-5` capture aussi `claude-opus-5-5`, qui serait alors facture au tarif Opus 5 ($5/$25, cache read $0.50 — 2,5x trop cher sur le cache read).
- Le tarif **legacy** ($15/$75) n'est applique qu'aux deux IDs retires Opus 4 et Opus 4.1 (`claude-opus-4-20250514`, `claude-opus-4-1-20250805`, leur forme Google Cloud `claude-opus-4-1@20250805` et leurs alias sans date `claude-opus-4`, `claude-opus-4-0`, `claude-opus-4-1`). Tout autre Opus non liste (futur `opus-4-9`, `opus-6`...) tombe dans la branche `opus` generique, **par hypothese** au tarif $5/$25 (fast x2 : $10/$50, comme Opus 5 / 4.8), et un futur `opus-5-x` autre que 5.5 est capture par `opus-5` (tarif Opus 5, fast compris). Un nouvel Opus est donc toujours chiffre, mais son tarif reel est a revalider a chaque sortie (Opus 5.5 est moins cher, Opus 4.1 etait plus cher).
- `fable-5-2|mythos-5-2` et `fable-5-1|mythos-5-1` **doivent** rester avant `fable|mythos`, qui les facturerait au tarif Fable 5 ($10/$50, cache read $1 : +36,7 % mesure sur une session Fable 5.2). Un futur Fable autre que 5.1 / 5.2 (`fable-5-3`, `fable-6`...) tomberait dans `fable|mythos` a ce tarif Fable 5 : a revalider a chaque sortie, chaque version ayant change le prix jusqu'ici (cache read x0.025 en 5.1, tarif de base et fast mode en 5.2).
- `sonnet-5-5` **doit** rester avant `sonnet-5` : la regex `sonnet-5` capture aussi `claude-sonnet-5-5`, qui serait alors facture avec le cache read de Sonnet 5 ($0.20 au lieu de $0.10 : +8,6 % mesure sur une session reelle). Un futur `sonnet-5-x` autre que 5.5 tomberait dans `sonnet-5` a $2/$10 : a revalider a chaque sortie.
- `haiku-5-5` **doit** rester avant `haiku` : la regex `haiku` capture aussi `claude-haiku-5-5`, qui serait alors facture au tarif Haiku 4.5 ($1/$5 : 10x trop cher sous le palier, 2x trop cher au-dessus). Un futur `haiku-5-x` autre que 5.5 tomberait dans `haiku` au tarif Haiku 4.5 : a revalider a chaque sortie (branche dediee a placer avant `haiku`).

### Fenêtre de la semaine

Le début de la semaine est la fin de fenêtre connue moins 7 jours : celle que Claude Code transmet (`rate_limits.seven_day.resets_at`), sinon celle de l'API, sinon la dernière en cache. Si la fin connue est déjà passée (API muette depuis), la fenêtre suivante a commencé à cette date : le début avance par pas de 7 jours. Les bornes sont converties en UTC par `jq` pour être comparées aux horodatages des JSONL, quel que soit le fuseau de la machine.

### Fast mode

Le fast mode (x2 sur Fable 5.2 / Mythos 5.2, Opus 5.5, Opus 5 et Opus 4.8 ; historiquement x6 sur Opus 4.6/4.7, retire depuis) est detecte de deux manieres :
- **Affichage ⚡** : lit le champ `.fast_mode` du JSON stdin, etat reel de la session (faux sur un modele sans fast mode, Fable 5.1, Sonnet ou Haiku par exemple, meme si `/fast` est memorise ; sur Fable 5.2, faux tant que `/fast` n'a pas ete lance sur ce modele, le reglage `fastMode` seul ne suffisant pas) ; repli sur `fastMode` dans `~/.claude/settings.json` si Claude Code est trop ancien pour exposer ce champ
- **Calcul cout** : lit le champ `speed` de chaque requete dans les JSONL (historique precis)

### Thinking tokens

Les thinking tokens sont inclus dans `output_tokens` sur le dernier chunk de streaming. Pas besoin de les compter separement. Le detail `usage.output_tokens_details.thinking_tokens` des JSONL recents (thinking toujours actif sur Fable 5.2 / 5.1, Opus 5.5 et Haiku 5.5) en est un sous-ensemble (toujours <= `output_tokens`) : l'ajouter compterait deux fois le thinking.

## Installation

### Installation rapide (recommandee)

Un installer cross-platform detecte l'OS et fait tout le necessaire :

```bash
npx github:jeremywtp/statusline-claude-code
```

Prerequis : Node 18+. Avec npm 12 ou plus recent, la commande devient `npx --allow-git=root github:jeremywtp/statusline-claude-code` (voir la note npm 12 sous [Commandes disponibles](#commandes-disponibles)). L'installer :

- copie `statusline.sh` vers `~/.claude/statusline.sh` (avec backup `.bak` horodate si un script existant est present)
- merge proprement la cle `statusLine` dans `~/.claude/settings.json` sans casser les autres cles (`env`, `permissions`, `enabledPlugins`, etc.)
- verifie / installe les dependances (`jq`, `curl`, `git`)
- applique le **patch macOS complet** (voir plus bas) si OS = Darwin

### Linux / WSL2

Dependances attendues : `jq`, `curl`, `git`, `bash 4+`. L'installer controle `jq`, `curl` et `git` : il refuse de continuer si l'un manque, et propose la commande apt/pacman/dnf adaptee. `bash 4+` n'est **pas** verifie a l'install (il est presume present sur Linux/WSL2) ; seule la commande `doctor` le remonte, a titre de diagnostic.

```bash
npx github:jeremywtp/statusline-claude-code
```

### macOS (Intel + Apple Silicon)

Le script d'origine utilise des commandes GNU incompatibles BSD (`stat -c`, `date -d`, `grep -oP`, `find -mmin`, et depend de Bash 5+). L'installer macOS :

1. verifie Homebrew (refuse si absent et renvoie la commande d'install Homebrew)
2. detecte Apple Silicon (`/opt/homebrew`) ou Intel (`/usr/local`)
3. `brew install coreutils findutils grep bash jq curl git` pour ce qui manque seulement
4. insere un **shim de compatibilite** dans `statusline.sh` qui redirige `stat`/`date`/`grep`/`find` vers leurs equivalents GNU (`gstat`, `gdate`, `ggrep`, `gfind`). Le shim couvre aussi `md5sum` → `gmd5sum` par precaution, mais le script ne l'appelle plus : le hachage des chemins passe par `cksum` (POSIX, natif BSD). Le verrou API utilise `mkdir` (atomique, natif partout), aucune dependance a `flock`
5. reecrit le shebang vers Bash 5+ Homebrew (macOS livre `/bin/bash` en 3.2)

Une fois installe, c'est **`statusline.sh` lui-meme** (pas l'installer) qui lit le token OAuth dans le **Keychain** (`security find-generic-password -s "Claude Code-credentials"`), en fallback de `~/.claude/.credentials.json` : Claude Code stocke le token dans le Keychain par defaut sur Mac, alors que sur Linux/WSL il l'ecrit dans le fichier. La commande `doctor` verifie la presence de l'un ou de l'autre.

Prerequis : avoir [Homebrew](https://brew.sh) installe (`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`).

```bash
npx github:jeremywtp/statusline-claude-code
```

### Windows

Pas de support natif (Claude Code et ses scripts bash ne tournent pas sur `cmd`/PowerShell). Installer [WSL2](https://learn.microsoft.com/fr-fr/windows/wsl/install) et lancer la commande depuis Ubuntu.

### Commandes disponibles

```bash
# Install / update (re-run pour mettre a jour)
npx github:jeremywtp/statusline-claude-code

# Diagnostic : OS, dependances, fichiers, credentials
npx github:jeremywtp/statusline-claude-code doctor

# Desinstallation (retire statusline.sh et la cle statusLine)
npx github:jeremywtp/statusline-claude-code uninstall

# Options
#   --no-backup        n'ecrit pas de .bak des fichiers modifies
#   --with-fetch-hook  ajoute le hook UserPromptSubmit "git fetch" sans demander
#   --no-fetch-hook    n'ajoute pas le hook (skip prompt en mode interactif)
```

> **npx en cache ou npm 10.8** : pour forcer une version precise, ajouter `#<commit>` (`npx github:jeremywtp/statusline-claude-code#<sha>`). Si npx echoue avec `GitFetcher requires an Arborist constructor to pack a tarball` (bug de npm 10.8, vu sous Ubuntu avec node 20), passer par l'archive GitHub, qui ne demande pas git : `npx https://codeload.github.com/jeremywtp/statusline-claude-code/tar.gz/main` (ou `/tar.gz/<sha>`), suivi de la commande voulue (`install`, `doctor`...).
>
> **npm 12** (verifie sur npm 12.2.1) : npx refuse par defaut les paquets git et les archives distantes — `EALLOWGIT` (`Fetching packages of type "git" have been disabled`) pour `github:...`, `EALLOWREMOTE` pour l'archive codeload. Trois issues, au choix : `npx --allow-git=root github:jeremywtp/statusline-claude-code` (l'option se place avant le nom du paquet, et se combine avec `#<sha>`), `npx --allow-remote=root https://codeload.github.com/jeremywtp/statusline-claude-code/tar.gz/main`, ou l'installeur lance depuis un clone du depot, sans npx : `node bin/install.mjs` (memes commandes et options).

### Installation manuelle (fallback)

Si l'installer npx ne convient pas, voir `bin/platforms/linux.mjs` et `bin/shims/macos.sh` pour les etapes exactes — ou simplement :

```bash
cp statusline.sh ~/.claude/statusline.sh && chmod +x ~/.claude/statusline.sh
```

Puis ajouter dans `~/.claude/settings.json` :

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 1
  }
}
```

> Sur macOS, il faut **en plus** installer `coreutils findutils grep bash` via Homebrew et injecter le shim `bin/shims/macos.sh` apres `set -euo pipefail` — l'installer npx gere tout ca automatiquement.

### Hook `UserPromptSubmit` (optionnel — pour `↓N` plus reactif)

Le statusline lance deja un `git fetch` en background si > 5 min depuis le dernier. Pour rendre `↓N` (commits remote non recuperes) **encore plus reactif**, l'installer propose un hook qui declenche un fetch detache a chaque message envoye.

**A l'install, le hook est propose via prompt interactif** :

```
> Hook UserPromptSubmit "git fetch" (optionnel)
  Lance "git fetch --quiet --no-tags" detache (background POSIX) a chaque message
  envoye, pour rendre ↓N (commits remote non recuperes) plus reactif.
  Sans le hook, l'auto-fetch tourne quand meme toutes les 5 min.

  Ajouter le hook UserPromptSubmit ? [y/N]
```

Pour les installs scriptees / CI (sans TTY), utiliser un flag explicite :

```bash
npx github:jeremywtp/statusline-claude-code --with-fetch-hook   # ajoute sans demander
npx github:jeremywtp/statusline-claude-code --no-fetch-hook     # skip propre
```

L'ajout est **idempotent** : relancer l'installer detecte le hook existant et ne le duplique pas. La detection est aussi compatible avec les anciennes installs sans marqueur (heuristique de signature). Si une ancienne version `& disown` est detectee, l'installer la **migre automatiquement** vers la version POSIX courante.

Si tu preferes ajouter le hook a la main, le snippet a merger dans `~/.claude/settings.json` :

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "(cd \"$CLAUDE_PROJECT_DIR\" && git rev-parse --git-dir >/dev/null 2>&1 && git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 && git fetch --quiet --no-tags 2>/dev/null) </dev/null >/dev/null 2>&1 & # scc-fetch-hook"
          }
        ]
      }
    ]
  }
}
```

La double verification (`rev-parse --git-dir` + `rev-parse --abbrev-ref @{u}`) evite :
- d'erreurer dans les dossiers non-git
- de prompter SSH/HTTPS inutilement sur les branches sans upstream tracke

La redirection des trois FDs (`</dev/null >/dev/null 2>&1`) suivie de `&` detache le fetch du processus parent : il **ne bloque jamais** l'envoi du message. POSIX volontairement (pas `disown`) car Claude Code execute les hooks via `/bin/sh` — sur Debian/Ubuntu/WSL2, `/bin/sh` est `dash`, qui n'a pas le builtin bash `disown`.

Le commentaire shell `# scc-fetch-hook` est un marqueur inerte qui sert a `npx ... uninstall` pour retirer **uniquement** ce hook sans toucher aux autres `UserPromptSubmit` que tu pourrais avoir ajoutes manuellement.

## Fichiers et cache

Le cache vit dans `~/.cache/claude-statusline/<profil>/` (`defaut` pour `~/.claude`, sinon le chemin de `CLAUDE_CONFIG_DIR` rendu en nom de dossier ; `$XDG_CACHE_HOME` est respecté). Dossier 700, fichiers 600. Chaque fichier commence par `v3|<date d'écriture>|` ; un fichier d'un autre format est ignoré.

| Fichier | Description | Durée |
|---|---|---|
| `~/.claude/statusline.sh` | Script principal (`/usr/local/lib/claude-statusline/statusline.sh` sur un serveur) | — |
| `~/.claude/settings.json` | Config Claude Code (statusLine) | — |
| `usage` | Quotas 5h / 7j / Fable de l'API et coûts 5h / 7j | 300s |
| `usage-pause` | Posé après un 429 : pas d'appel à l'API pendant 10 min | 600s |
| `statut` | Statut de Claude (status.claude.com) | 60s |
| `serveur`, `pm2-apps` | Mode serveur : PM2, builds, sessions, disques, plus gros consommateur de mémoire ; dossier, nom et état de chaque app | 45s |
| `cpu` | Mode serveur : dernier relevé des compteurs du processeur | 5s au moins entre deux relevés |
| `git-<session>` | État git du dossier courant de la session, date du dernier fetch | 5s |
| `trame-<session>` | Mode serveur : les trois lignes du dernier rendu complet et l'entrée reçue, pour la voie rapide | 15s |
| `extraits/` | Un extrait par JSONL (usage par requête), refait quand le JSONL change | 8 jours |
| `verrou.d/` | Verrou `mkdir` du rafraîchissement d'arrière-plan (PID et date ; repris si le processus n'existe plus) | — |

Les anciens fichiers (`/tmp/claude-sl-<uid>-*`, `~/.claude/usage-session`, `~/.claude/week-session`) ne sont plus lus ni écrits : ils peuvent être supprimés.

## Rafraîchissement d'arrière-plan

Le rendu ne lit que le cache. Quand un fichier est périmé, il lance `statusline.sh --rafraichir` en processus détaché (`setsid` quand il existe, entrée et sorties fermées) : Claude Code n'attend pas sa fin et peut annuler un rendu sans l'interrompre. Un seul rafraîchissement tourne à la fois par profil, à la priorité la plus basse.

- **API des quotas** (`/api/oauth/usage`, sujette au rate limiting) : sur 429, pause de 10 min ; en cas d'échec, les dernières valeurs connues restent affichées. Le header `User-Agent: claude-code/<version>` est obligatoire.
- **Statut de Claude** : point gris tant que l'état n'est pas connu (premier rendu, réseau muet), jamais un faux vert.
- **Premier rendu** : les quotas transmis par Claude Code s'affichent tout de suite ; quota Fable et coûts arrivent au rendu suivant. Régler `refreshInterval` dans `statusLine` (15 à 30 s) fait apparaître les valeurs sans attendre le prochain message.

## Rafraîchissement en direct de la ligne du serveur

Sur un serveur, Claude Code relance le script toutes les 2 secondes (`refreshInterval`). Refaire tout le rendu à chaque fois coûterait un `jq`, un `git` et la lecture du fichier entier. Quand rien n'a changé dans ce que Claude Code transmet (hors durée de session), le script prend une **voie rapide** placée en tête de fichier : il reprend telles quelles les trois lignes du dernier rendu complet, ne recalcule que la ligne du serveur à partir de `/proc`, et s'arrête ; la suite du fichier n'est ni lue ni exécutée.

Un rendu complet revient dès que l'entrée change (nouvelle réponse, autre dossier), que la largeur du terminal change, qu'un cache d'arrière-plan vient d'être rafraîchi, ou au bout de 15 secondes. Une trame qui porterait autre chose que des couleurs est refusée.

Mesuré le 13/11/2026 sur des serveurs en service, script en mémoire : 13 à 39 ms par affichage en voie rapide, 38 à 107 ms par rendu complet. À 2 secondes d'intervalle, cela fait de l'ordre de 1 à 3 % d'un cœur par session ouverte (estimation à partir de ces mesures), et rien quand aucune session n'est ouverte. Disque, PM2, builds et sessions restent relevés toutes les 45 secondes : ils ne bougent pas plus vite.

## Plusieurs comptes Claude (`CLAUDE_CONFIG_DIR`)

Un second compte Claude tourne dans son propre profil : `CLAUDE_CONFIG_DIR=~/.claude-compte2 claude`. La statusline le detecte et isole tout ce qui appartient au compte :

| Element | Profil par defaut (`~/.claude`) | Autre profil (`CLAUDE_CONFIG_DIR`) |
|---|---|---|
| Jeton OAuth (quotas 5h / 7j / Fable) | Trousseau `Claude Code-credentials` (macOS) ou `~/.claude/.credentials.json` (Linux) | Trousseau `Claude Code-credentials-<8 hex>` (macOS) ou `<profil>/.credentials.json` (Linux) — **jamais** de repli sur le jeton du profil par defaut |
| Cache (quotas, coûts, statut, git, verrou) | `~/.cache/claude-statusline/defaut/` | `~/.cache/claude-statusline/<chemin du profil>/` |
| `settings.json` lu en repli | `~/.claude/` | `<profil>/` |
| JSONL scannes pour les couts | `~/.claude/projects/` | `<profil>/projects/` |

`<8 hex>` = les 8 premiers caracteres du sha256 du chemin `CLAUDE_CONFIG_DIR` tel qu'il est exporte : c'est le suffixe que Claude Code donne lui-meme a l'entree Trousseau du profil.

Quand la session reçoit son jeton par l'environnement (`CLAUDE_CODE_OAUTH_TOKEN`, cas d'un lanceur qui choisit le compte), c'est ce jeton qui interroge l'API, pas celui du fichier du profil : les quotas affichés sont ceux du compte qui paie la session.

Un seul script sert tous les profils : l'installeur ecrit `~/.claude/statusline.sh` et `~/.claude/settings.json`, et un profil qui partage sa configuration par liens symboliques (`<profil>/settings.json -> ~/.claude/settings.json`, idem `statusline.sh`) en herite sans reinstallation. L'installeur ecrit a travers ces liens sans les remplacer.

**Limite — historique partage** : si `<profil>/projects` est un lien vers `~/.claude/projects` (sessions reprises d'un compte a l'autre), les JSONL des deux comptes sont melanges et ne portent aucun identifiant de compte par message : les **couts** 5h / 7j cumulent alors la consommation des deux comptes (chacun sur la fenetre de son propre compte). Les **pourcentages** de quota, eux, restent exacts pour chaque compte (API OAuth du compte).

## Fonctionnement

Claude Code pipe un objet JSON via stdin a chaque render. Le script le parse en **un seul appel `jq`** pour en extraire le modele, le contexte, la session (cout, duree), le repertoire, la version, l'agent, le mode vim, le chemin du transcript, l'effort level et l'etat du fast mode.

Le git n'est **pas** dans ce JSON : la branche et les compteurs (staged / modifies / untracked, ahead / behind) sont obtenus en lancant de vraies commandes `git` dans le repertoire transmis par le JSON (`workspace.current_dir`).

Rien de lent ne se fait dans le rendu : git est mis en cache 5 secondes par session, et l'API des quotas, le statut, les coûts et l'état du serveur sont tenus à jour par le [rafraîchissement d'arrière-plan](#rafraîchissement-darrière-plan). Mesuré sur un Mac M-series, caches chauds : 15 ms par rendu (86 ms auparavant) ; sur les serveurs, 40 à 110 ms sans cache selon la machine (`jq` 1.6 d'Ubuntu 22.04 met à lui seul 30 ms à démarrer).

## Compatibilite

- **Locale** — le script force `LC_NUMERIC=C` au demarrage pour que `printf '%.Nf'` accepte les valeurs avec `.` (sans ca, en `fr_FR.UTF-8` qui attend `,`, tous les pourcentages et couts retombent a 0)
- **Token OAuth** — sur macOS, lu dans le Keychain `Claude Code-credentials` ; sur Linux/WSL, lu dans `~/.claude/.credentials.json`. La lecture essaie le fichier en priorite et tombe sur le Keychain si vide ET `uname = Darwin`
- **Couleurs** — toutes les couleurs sont en palette 256 (codes `\033[38;5;N` avec N >= 16) pour garantir un rendu identique sur tous les terminaux. Les codes 16-couleurs (30-37 / 90-97) sont remappes par certains terminaux (cmux, Solarized, etc.) ce qui faisait ressortir le vert en jaune et le violet en violet pale

### Effort level — sources et priorite

Claude Code applique l'effort level dans cet ordre (le premier qui matche gagne) :

1. **`CLAUDE_CODE_EFFORT_LEVEL` env var** — override absolu. Quand elle est posee, `/effort <X>` UI est bloquee : Claude Code repond `CLAUDE_CODE_EFFORT_LEVEL=<X> overrides this session — clear it and <Y> takes over`.
2. **`/effort <X>` UI dans la session courante** — override session-only.
3. **Niveau memorise dans `~/.claude/settings.json`** — baseline persistante. Depuis Claude Code v2.1.251, `/effort` l'enregistre par modele (`modelSettings.<id>.effortLevel`), prioritaire sur la cle `effortLevel` de premier niveau. Cette ancienne cle ne s'applique plus a Opus 5.5 (ni aux modeles ulterieurs) dans le fichier utilisateur.
4. **Defaut modele** — `medium` sur Fable 5.2 / Mythos 5.2, Opus 5.5, Sonnet 5.5 et Haiku 5.5 (pour Fable 5.2 et Sonnet 5.5 c'est un defaut propre a Claude Code, l'API restant a `high` ; Opus 5.5 et Haiku 5.5 sont a `medium` cote API aussi), `xhigh` sur Opus 4.7, `high` sur tous les autres modeles a effort (Opus 4.8 / 5, Fable 5 / 5.1, Sonnet 5...).

La statusline lit en priorite le champ **`.effort.level` du JSON stdin** transmis par Claude Code : c'est la valeur live deja resolue (elle reflete `/effort` en cours de session, l'env var, `settings.json` et le defaut modele). Cas particulier **ultracode** : Claude Code le mappe en interne sur `xhigh`, donc `.effort.level` renvoie `xhigh` (indistinct d'un vrai xhigh) ; pour l'afficher distinctement (`▌▌▌▌▌ ✦`), la statusline ne leve l'ambiguite que dans ce cas, en lisant le dernier `Set effort level to ultracode` du transcript.

Si `.effort.level` est absent (Claude Code trop ancien, ou modele sans effort comme Haiku 4.5), elle retombe sur le fallback historique. Sa preseance est **`CLAUDE_CODE_EFFORT_LEVEL` > `/effort` dans le transcript > `effortLevel` de `settings.json`** : le script lit les trois sources dans l'ordre inverse, chacune ecrasant la precedente, donc c'est bien la derniere lue (l'env var) qui gagne. Cet ordre approxime celui de Claude Code decrit ci-dessus, sans le niveau par modele (`modelSettings`, inutile ici : toute version de Claude Code qui l'ecrit fournit deja `.effort.level`) ni le defaut exact du modele (`default` s'affiche comme `medium`).

Le transcript est interroge avec deux patterns : d'abord `Set effort level to <X>` (ecrit lors d'un `/effort`), puis en repli `(current )?effort level: <X>` (lookahead 50 chars) qui couvre l'affichage de `/effort` sans argument.

**Detail technique du pattern grep `/effort`** : Claude Code ecrit deux formats distincts dans `local-command-stdout` selon que le niveau est persistant ou session-only :

- `low` / `medium` / `high` / `xhigh` (persistants) → `Set effort level to <X>: <description>`
- `max` (session-only) → `Set effort level to max (this session only): <description>`

Le pattern doit donc tolerer un suffixe variable :

```
local-command-stdout>Set effort level to \K\w+(?=[^<>]{0,200}</local-command-stdout>)
```

Le lookahead 200 chars couvre toutes les descriptions (jusqu'a ~95 chars pour `high`) tout en restant anti-faux-positif (le code source du statusline lu via Read et stocke dans le JSONL n'a pas `</local-command-stdout>` a proximite immediate).

## Essais

```bash
tests/essais.sh        # 106 essais, dans un dossier temporaire : aucun réseau, aucun vrai jeton
tests/essais.sh -v     # avec les rendus
tests/couts-reels.sh   # coûts de la branche main et de la version courante sur vos transcriptions (lecture seule)
```

La suite couvre le rendu, l'absence de fichier hors du cache, le trajet du jeton, l'injection par l'affichage et par le calcul, les entrées dégradées, la largeur (34 à 200 colonnes), les quotas, les coûts (calcul à la main, lecture incrémentale, ligne tronquée), l'attente du réseau et de git, la comparaison avec la branche `main`, le mode serveur et l'installation sur un serveur. Sur macOS elle insère le shim GNU comme le fait l'installeur.

## Licence

MIT
