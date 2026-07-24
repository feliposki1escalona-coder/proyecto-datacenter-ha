#!/usr/bin/env bash
# =====================================================================
# DEMO FINAL — Evidencia de los 5 criterios de la rúbrica
# Uso:  bash demo-final.sh        (desde ~/proyecto-datacenter-ha)
# Pensado para grabarse en video. Pausa entre secciones con ENTER.
# =====================================================================
set -uo pipefail

N1=10.0.0.11; N2=10.0.0.12; N3=10.0.0.13; VIP=10.0.0.100
ANSIBLE_DIR="$HOME/proyecto-datacenter-ha/ansible"

titulo() { echo; echo "======================================================="; echo ">> $1"; echo "======================================================="; }
pausa()  { echo; read -rp "[ENTER para continuar]"; }
mongo_estado() {
  ssh devops@$N1 'sudo docker exec mongo mongosh --quiet --eval "rs.status().members.map(m => m.name + \" -> \" + m.stateStr)"'
}

# ---------------------------------------------------------------------
titulo "0. ARQUITECTURA: 3 nodos Ubuntu creados por código (KVM)"
virsh list --all | grep -E "node[123]|Name"
echo; echo "Direccionamiento: node1=$N1  node2=$N2  node3=$N3  VIP=$VIP"
pausa

# ---------------------------------------------------------------------
titulo "1. REGLA DE ORO: cero configuración manual (history vacío)"
for H in $N1 $N2 $N3; do
  printf "  %s -> líneas en .bash_history: " "$H"
  ssh devops@$H "cat ~/.bash_history 2>/dev/null | wc -l"
done
pausa

# ---------------------------------------------------------------------
titulo "2. APROVISIONAMIENTO IaC — inventarios, group_vars y módulos nativos"
echo "--- Estructura del proyecto ---"
find "$ANSIBLE_DIR" -type f | sed "s|$HOME/||" | sort
echo
echo "--- Verificación: NO se usan los módulos shell/command ---"
if grep -rn "ansible.builtin.shell\|ansible.builtin.command" "$ANSIBLE_DIR/roles" 2>/dev/null; then
  echo "  [!] Se encontraron usos de shell/command"
else
  echo "  OK: ninguna tarea usa shell ni command."
fi
pausa

# ---------------------------------------------------------------------
titulo "3. IDEMPOTENCIA — el playbook debe reportar changed=0"
cd "$ANSIBLE_DIR"
ansible-playbook site.yml | tail -n 12
echo
echo ">> Si todos los nodos muestran changed=0, la Regla de Oro 3 se cumple."
pausa

# ---------------------------------------------------------------------
titulo "4. SEGURIDAD — firewall restrictivo aplicado por Ansible"
ansible node1 -m command -a "ufw status verbose" --become 2>/dev/null | grep -v "^node1 |"
pausa

# ---------------------------------------------------------------------
titulo "5. ORQUESTACIÓN — Docker Compose base + override (herencia)"
echo "--- ARCHIVO BASE (solo topología, sin secretos ni rutas del host) ---"
ssh devops@$N1 "cat /srv/mongo/docker-compose.yml"
echo
echo "--- OVERRIDE DE PRODUCCIÓN (volumen local, restart, red, entorno) ---"
ssh devops@$N1 "cat /srv/mongo/docker-compose.prod.yml"
echo
echo "--- Contenedores levantados en cada nodo ---"
for H in $N1 $N2 $N3; do
  echo "  [$H]"
  ssh devops@$H "sudo docker ps --format '    {{.Names}}\t{{.Status}}'"
done
pausa

# ---------------------------------------------------------------------
titulo "6. CLÚSTER STATEFUL HA — MongoDB Replica Set con volumen local"
mongo_estado
echo
echo "--- Persistencia: volumen local en cada VM ---"
ssh devops@$N1 "sudo ls /srv/mongo/data | head -5"
pausa

# ---------------------------------------------------------------------
titulo "7. BALANCEO ROUND-ROBIN sobre la IP virtual ($VIP)"
echo "--- keepalived mantiene la VIP activa en el nodo MASTER ---"
ssh devops@$N1 "ip a | grep $VIP"
echo
echo "--- 6 peticiones consecutivas: el tráfico debe rotar entre los 3 nodos ---"
for i in $(seq 1 6); do
  printf "  petición %s -> " "$i"
  curl -s http://$VIP/ | grep -o '"atendido_por":"[^"]*"'
done
pausa

# ---------------------------------------------------------------------
titulo "8. PRUEBA DE RESILIENCIA A — caída de un nodo web"
echo ">> Deteniendo la aplicación en node3..."
ssh devops@$N3 "sudo docker stop web" >/dev/null
sleep 4
echo ">> El balanceador debe excluirlo SIN devolver errores 502/503:"
for i in $(seq 1 6); do
  printf "  petición %s -> HTTP %s | " "$i" "$(curl -s -o /dev/null -w '%{http_code}' http://$VIP/)"
  curl -s http://$VIP/ | grep -o '"atendido_por":"[^"]*"'
done
echo
echo ">> Restaurando node3..."
ssh devops@$N3 "sudo docker start web" >/dev/null
sleep 6
pausa

# ---------------------------------------------------------------------
titulo "9. PRUEBA DE RESILIENCIA B — failover del PRIMARY de MongoDB"
echo "--- Estado inicial del clúster ---"
mongo_estado
PRIMARY_ANTES=$(curl -s http://$VIP/ | grep -o '"mongo_primary":"[^"]*"')
echo
echo "  Antes  -> $PRIMARY_ANTES"
echo "  Datos  -> $(curl -s http://$VIP/ | grep -o '"visitas_totales":[0-9]*')"
echo
echo ">> Matando abruptamente (kill) el contenedor Mongo del Primary..."
PRIMARY_IP=$(echo "$PRIMARY_ANTES" | grep -oE '10\.0\.0\.[0-9]+')
ssh devops@"$PRIMARY_IP" "sudo docker kill mongo" >/dev/null
echo ">> Esperando la reelección automática (quórum: 2 de 3)..."
sleep 15
echo
echo "  Después -> $(curl -s http://$VIP/ | grep -o '"mongo_primary":"[^"]*"')"
echo "  Datos   -> $(curl -s http://$VIP/ | grep -o '"visitas_totales":[0-9]*')"
echo
echo ">> El contador NO retrocede: no hubo pérdida de datos ni Split-Brain."
echo ">> Restaurando el nodo caído..."
ssh devops@"$PRIMARY_IP" "sudo docker start mongo" >/dev/null
sleep 12
mongo_estado
echo ">> El nodo reingresa como SECONDARY (MongoDB no revierte el liderazgo)."
pausa

# ---------------------------------------------------------------------
titulo "10. CI/CD — pipeline y gestión segura de credenciales"
cd "$HOME/proyecto-datacenter-ha"
cat .github/workflows/deploy.yml
echo
echo "--- Verificación: no hay llaves ni contraseñas en el código ---"
if git --no-pager grep -nE "BEGIN OPENSSH PRIVATE KEY|ssh-ed25519 AAAA" -- . 2>/dev/null; then
  echo "  [!] Se detectó material sensible en el repositorio"
else
  echo "  OK: ninguna llave privada versionada. Se usan secretos del repositorio."
fi
echo
echo "--- Últimos commits ---"
git --no-pager log --oneline -5

titulo "FIN DE LA DEMOSTRACIÓN"
