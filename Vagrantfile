# Three Ubuntu 24.04 VMs on a private host-only network, configured by Salt
# (masterless, from the shared /vagrant folder).
#
#   vagrant up                       # VirtualBox (Windows / macOS / Linux)
#   vagrant up --provider=libvirt    # KVM/QEMU on a Linux host (needs vagrant-libvirt)
#
# Nodes come up in order, so db1 bootstraps the cluster and db2/db3 join it.
# Needs ~3.5 GB free RAM.
NODES = {
  "db1" => "192.168.56.11",
  "db2" => "192.168.56.12",
  "db3" => "192.168.56.13",
}

Vagrant.configure("2") do |config|
  config.vm.box = ENV.fetch("LAB_BOX", "bento/ubuntu-24.04")

  NODES.each do |name, ip|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: ip

      node.vm.provider "virtualbox" do |vb|
        vb.name = "galera-lab-#{name}"
        vb.memory = 1024
        vb.cpus = 1
      end

      node.vm.provider "libvirt" do |lv|
        lv.memory = 1024
        lv.cpus = 1
      end

      node.vm.provision "shell", path: "scripts/vagrant_provision.sh", args: [name]
    end
  end
end
