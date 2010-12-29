#
require 'puppet/provider/aixobject'
require 'puppet/provider/mount'

require 'tempfile'
require 'date'

Puppet::Type.type(:mount).provide :aix, :parent => Puppet::Provider::AixObject do
  desc "Mount management for AIX! mountpoints are managed with mkfs, rmfs, chfs, lsfs"

  # This will the the default provider for this platform
  defaultfor :operatingsystem => :aix
  confine :operatingsystem => :aix

  # Commands that manage the element
  commands :list      => "/usr/sbin/lsfs"
  commands :add       => "/usr/sbin/crfs"
  commands :delete    => "/usr/sbin/rmfs"
  commands :modify    => "/usr/sbin/chfs"

  commands :chnfsmnt    => "/usr/sbin/chnfsmnt"
  commands :mountcmd => "mount", :umount => "umount"

  # Mount functionality 
  include Puppet::Provider::Mount
  
  # Valid attributes to be managed by this provider.
  # It is a list of hashes
  #  :aix_attr      AIX command attribute name
  #  :puppet_prop   Puppet propertie name
  #  :to            Optional. Method name that adapts puppet property to aix command value. 
  #  :from          Optional. Method to adapt aix command line value to puppet property. Optional
  #  :to_arg        Optional. Method that will converts given value to a ch* (modify) or mk* (modify)
  #                 command argument. By default is converted to key=value.
  self.attribute_mapping = [
    #:name => :name,
    {:aix_attr => :automount,       :puppet_prop => :atboot },
    {:aix_attr => :device,          :puppet_prop => :device},
    {:aix_attr => :nodename,        :puppet_prop => :nodename},
    {:aix_attr => :vfs,             :puppet_prop => :fstype},
    {:aix_attr => :options,         :puppet_prop => :options},
    {:aix_attr => :size,            :puppet_prop => :size},
    {:aix_attr => :volume,          :puppet_prop => :volume},
  ]
  
  #--------------
  def lscmd(value=@resource[:name])
    # -c: Specifies that the output should be in colon format.
    [self.class.command(:list), "-c", value]
  end

  def lsallcmd()
    # -c: Specifies that the output should be in colon format.
    [self.class.command(:list), "-c"]
  end

  def addcmd(extra_attrs = [])
    args = self.hash2args(@resource.to_hash)
    
    [self.class.command(:add), "-m", @resource[:name] ] + 
      self.hash2args(@resource.to_hash)
  end

  def modifycmd(hash = property_hash)
    # Workaround. Chfs does not allow change the remote directory for
    # NFS mountpoints, so we will use chnfsmnt just for that 
    alt_hast = hash
    if hash[:device] and hash[:device] =~ /^.*:.*/
      # In the chnfsmnt command, the hostname is specified with '-h', not '-n'
      args = self.hash2args(hash)
      args.map!{|x| case x when '-n' then '-h' when '-V' then '-m' else x end}
      [ self.class.command(:chnfsmnt), "-f", @resource[:name] ] + args
    elsif hash[:fstype] and hash[:fstype] =~ /^nfs/
      # Add the device.
      # In the chnfsmnt command, the hostname is specified with '-h', not '-n'
      hash[:device] = self.getinfo()[:device]
      args = self.hash2args(hash)
      args.map!{|x| case x when '-n' then '-h' when '-V' then '-m' else x end}
      [ self.class.command(:chnfsmnt), "-d", @resource[:name] ] + args
    elsif hash[:fstype]
      raise Puppet::Error, "Can not change the fstype in AIX in  #{@resource.class.name} #{@resource.name}."
    else
      args = self.hash2args(hash)
      if ! args.empty?
        [ self.class.command(:modify) ] + args + [ @resource[:name] ]
      else
        # Return nil if argument is unknown
        nil
      end
    end
  end

  def deletecmd
    [self.class.command(:delete), @resource[:name]]
  end
  
  #--------------
  def load_attribute(key, value, mapping, objectinfo)
    if key == :automount
      # Convert the value to a bool
      value = (value.downcase == "yes")
    elsif key == :device
      # If objectinfo has a :nodename, is an nfs, add the nodename to value
      if objectinfo[:nodename] and not objectinfo[:nodename].empty?
        value = "#{objectinfo[:nodename]}:#{value}"
      end
    elsif key == :nodename
      # If objectinfo has a :device already defined, update it
      if objectinfo[:device] and not objectinfo[:device].empty? and not value.empty?
        objectinfo[:device] = "#{value}:#{objectinfo[:device]}"
      end
    elsif key == :options and value.empty?
      raise Puppet::Error, "Parameter options must not be empty for #{@resource.class.name} #{@resource.name}."
    end
    super(key, value, mapping, objectinfo)
  end

  def get_arguments(key, value, mapping, objectinfo)
    args = []
    if key == :atboot
      # Convert the value to a a string: yes|no
      args = value ? [ "-A", "yes" ] : [ "-A", "no" ]
    elsif key == :device
      # Check if device is a NFS url
      if value =~ /^.*:.*/
        nodename = value.split(':')[0]
        device = value.split(':')[1]
        # Be careful, when modifing 
        args = [ "-n", nodename, "-d", device ]
      else
        args = [ "-d", value ]
      end
    elsif key == :nodename
      true
    elsif key == :options
      args = [ "-a", "options=#{value}" ]
    elsif key == :fstype
      args = [ "-v", value ]
    elsif key == :size
      args = [ "-a", "size=#{value}" ]
    elsif key == :volume
      args = [ "-g", value ]
    #else
    #  Puppet.debug "No adding arguments for param '#{key.to_s}' in  #{@resource.class.name} #{@resource.name}."
    end
    return args
    
  end
  
  # Destroy the mountpoint. Call delete
  def destroy
    self.delete
  end
  
  # We overwrite delete because we will only delete nfs mountpoints
  def delete
    if ! objectinfo = self.getinfo()
      info "already absent"
      return nil
    end
        
    # Check to protect from incorrect removals.         
    if ((objectinfo[:fstype] and objectinfo[:fstype] !~ /^nfs/) or
        (objectinfo[:device] and ! objectinfo[:device].include? ':')) and
        ! (@resource[:force] and @resource[:force].downcase == "yes, i am sure")
      raise Puppet::Error,
        "Cowardly refusing to remove #{@resource.class.name} #{@resource.name}. " +
        "It will silently delete the LV and remove all data. " +
        "Set 'force' parameter to 'Yes, I am sure' to force removal."
    end
    
    super
    
  end
  
  # Ignore parameters dump and pass, not used in AIX
  def dump
    0
  end
  
  def dump=(v)
    Puppet.debug "'dump' parameter is ignored in  this provider for #{@resource.class.name} #{@resource.name}."
    0
  end
  
  def pass
    0
  end
  
  def pass=(v)
    Puppet.debug "'pass' parameter is ignored in  this provider for #{@resource.class.name} #{@resource.name}."
    0
  end
  
  
end
