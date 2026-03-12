defmodule Store.Tools do
  @moduledoc """
  Tools domain for lead-generation tools and submissions.
  """

  use Ash.Domain

  resources do
    resource(Store.Tools.LeadSubmission)
  end
end
