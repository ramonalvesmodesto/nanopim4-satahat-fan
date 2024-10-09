## Modificado para o Nanopi R2S
``` bash
wget https://raw.githubusercontent.com/ramonalvesmodesto/nanopim4-satahat-fan/refs/heads/master/pwm-fan.sh -O /etc/pwm-fan.sh
wget https://raw.githubusercontent.com/ramonalvesmodesto/nanopim4-satahat-fan/refs/heads/master/pwmfan -O /etc/init.d/pwmfan
chmod +x /etc/init.d/pwmfan
chmod +x /etc/pwm-fan.sh
/etc/init.d/pwmfan enable
/etc/init.d/pwmfan start
```
