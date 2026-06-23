-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
if vim.g.loaded_pi_dev_nvim == 1 then
  return
end
vim.g.loaded_pi_dev_nvim = 1

require('pi-dev').setup(vim.g.pi_dev_nvim or {})
