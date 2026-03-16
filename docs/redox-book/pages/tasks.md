# Tasks


This page contain commands used for common and specific tasks on Redox.

- Hardware
- System
- Networking
- User
- Files and Folders
- Media
- Graphics
## Hardware

### Show CPU information

```
cat /scheme/sys/cpu

```

## System

### Change current keyboard layout (map)


- Show all available layouts
```
inputd --keymaps

```


- Change current layout
```
inputd -K layout-name

```

### Show system information

```
uname -a

```


Or
```
screenfetch

```

### Show memory (RAM) information

```
free -h

```

### Show storage information

```
df -h

```

### Shutdown the computer

```
sudo shutdown

```

### Show all running processes

```
ps

```

### Show system-wide common programs

```
ls /usr/bin

```

### Show all schemes

```
ls /scheme

```

### Show all scheme resources

```
ls /scheme/scheme-name

```

### Show the system log

```
dmesg

```


Or
```
cat /scheme/sys/log

```

## Networking

#### Show system DNS name

```
hostname

```

#### Show all network addresses of your system

```
hostname -I

```

### Ping a website or IP

```
ping (website-url/ip-address)

```

### Show website information

```
whois https://website-name.com

```

### Download a Git repository

```
git clone https://website-name.com/repository-name

```

### Download a Git repository to the specified directory

```
git clone https://website-name.com/repository-name folder-name

```

### Download a file with wget

```
wget https://website-name.com/file-name

```

### Resume an incomplete download

```
wget -c https://website-name.com/file-name

```

### Download from multiple links in a text file

```
wget -i file.txt

```

### Download an entire website and convert it to work locally (offline)

```
wget --recursive --page-requisites --html-extension --convert-links --no-parent https://website-name.com

```

### Download a file with curl

```
curl -O https://website-name.com

```

### Download files from multiple websites at once

```
curl -O https://website-name.com/file-name -O https://website2-name.com/file-name

```

### Host a website with [Simple HTTP Server


- Point the program to the website folder
- The Home page of the website should be available on the root of the folder
- The Home page should be named as `index.html`
```
simple-http-server -i -p 80 folder-name

```


This command will use the port 80 (the certified port for HTTP servers), you can change as you wish.
## User

### Clean the terminal content

```
clear

```

### Exit the terminal session, current shell or root privileges

```
exit

```

### Current user on the shell

```
whoami

```

### Show the default terminal shell

```
echo $SHELL

```

### Show your current terminal shell

```
echo $0

```

### Show your installed terminal shells (active on $PATH)

```
cat /etc/shells

```

### Change your default terminal shell permanently (common path is `/usr/bin`)

```
chsh -s /path/of/your/shell

```

### Add an abbreviation for a command on the Ion shell

```
alias name='command'

```

### Change the user password

```
passwd user-name

```

### Show the commands history

```
history

```

### Show the commands with the name specified in history

```
history name

```

### Change the ownership of a file, folder, device and mounted-partition (recursively)

```
sudo chown -R user-name:group-name directory-name

```


Or
```
chown user-name file-name

```

### Show system-wide configuration files

```
ls /etc

```

### Show the user configuration files of programs

```
ls ~/.local/share ~/.config

```

### Print a text on terminal

```
echo text

```

### Show the directory paths in the `PATH` environment variable

```
echo $PATH

```

### Show the dynamically linked libraries used by a program

```
ldd program-name

```

### Add a new directory on the `PATH` environment variable of the Ion shell

```
TODO

```

### Restore the shell variables to default values

```
reset

```

### Measure the time spent by a program to run a command

```
time command

```

### Run a executable file on the current directory

```
./

```

### Run a non-executable shell script

```
sh script-name

```


Or
```
bash script-name

```

## Files and Folders

### Show files and folders in the current directory

```
ls

```

### Print some text file

```
cat file-name

```

### Edit a text file

```
kibi file-name

```


Save your changes by pressing Ctrl+S
### Show the current directory

```
pwd

```

### Change the active directory to the specified folder

```
cd folder-name

```

### Change to the previous directory

```
cd -

```

### Change to the upper directory

```
cd ..

```

### Change the current directory to the user folder

```
cd ~

```

### Show files and folders (including the hidden ones)

```
ls -A

```

### Show the files, folders and subfolders

```
ls *

```

### Show advanced information about the files/folders of the directory

```
ls -l

```

### Create a new folder

```
mkdir folder-name

```

### Copy a file

```
cp -v file-name destination-folder

```

### Copy a folder

```
cp -v folder-name destination-folder

```

### Move a folder

```
mv folder-name destination-folder

```

### Remove a file

```
rm file-name

```

### Remove a folder


(Use with caution if you called the command with `su`, `sudo` or `doas`)
```
rm -rf folder-name

```

### Add text in a text file

```
echo "text" >> directory/file

```

### Search for files

```
find . -type f -name file-name

```


(Run with `sudo` or `su` if these directories are under root permissions)
### Search for folders

```
find . -type d -name folder-name

```


(Run with `sudo` or `su` if the directories are under root permissions)
### Show files/folders in a tree

```
tree

```

## Media

### Play a video

```
ffplay video-name

```

### Play a music

```
ffplay music-name

```

### Show an image

```
image-viewer image-name

```

## Graphics

### Show the OpenGL information

```
glxinfo | grep OpenGL

```
