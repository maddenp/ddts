require 'library'

module Ex_Run

  include Library

  alias lib_outfiles lib_outfiles_ex

end

module Ex_Suite

  include Library

  alias lib_suite_post lib_suite_post_ex
  alias lib_suite_prep lib_suite_prep_ex

end
