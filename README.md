# WP Move

Copy remote wordpress installation to a local machine, with some extra features

## How to use

#### install script globally
```
git clone https://github.com/endriu84/wp-move.git
chmod +x wp-move/wp-move.sh
cp wp-move.sh /usr/local/bin/wp-move
cp .wp-move.sh /usr/local/bin/.wp-move.sh
```
#### initialize wp-move.json config file
```
cd project-name
wp-move --init
```

#### edit wp-move.json
```
nano wp-move.ymal
```
#### sync remote wp installation to Your localhost
```
wp-move
```
#### run the same command to update Your local copy

### Avalilable options

```
Usage: wp-move [OPTION]

Options (when no option is provided, then we do first 3 steps listed below)
    --files    sync files
    --config   generate wp-config.php file
    --db       sync database
    --init     generate wp-move.yml configuration file
    --help     show this help
```
