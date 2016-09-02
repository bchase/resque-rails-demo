class CreateExports < ActiveRecord::Migration[5.0]
  def change
    create_table :exports do |t|
      t.boolean :complete

      t.timestamps
    end
  end
end
